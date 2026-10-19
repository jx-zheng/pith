import AVFoundation
import Foundation
import PithCore

enum AVExportRunner {
    static func export(source: URL, destination: URL, output: FileType, progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        let preset: String
        let fileType: AVFileType
        if output.family == "m4a" {
            preset = AVAssetExportPresetAppleM4A
            fileType = .m4a
        } else if output.family == "mov" {
            preset = AVAssetExportPresetHighestQuality
            fileType = .mov
        } else {
            preset = AVAssetExportPresetHighestQuality
            fileType = .mp4
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConversionFailure.unsupported("AVFoundation can't export \(source.lastPathComponent).")
        }
        session.outputURL = destination
        session.outputFileType = fileType
        let poll = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                poll.cancel()
                switch session.status {
                case .completed:
                    progress(1)
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: ConversionFailure.cancelled)
                default:
                    let message = session.error?.localizedDescription ?? "Export failed."
                    continuation.resume(throwing: ConversionFailure.toolFailed(message))
                }
            }
        }
    }
}

enum MediaRunner {
    static func convert(
        source: URL,
        destination: URL,
        output: FileType,
        settings: PithSettings,
        tools: ToolAvailability,
        runner: ProcessRunner,
        trim: TrimRange? = nil,
        allowNative: Bool = true,
        progress: @escaping (Double) -> Void
    ) async throws {
        // AVAssetExportSession presets can't take a bitrate or a range, so Compress and Trim
        // (allowNative false) always go through ffmpeg.
        if allowNative, trim == nil, MediaRouter.prefersAVFoundation(input: FileTypes.matching(path: source.path) ?? output, output: output) {
            do {
                try await AVExportRunner.export(source: source, destination: destination, output: output, progress: progress)
                return
            } catch {
                if tools.ffmpeg == nil { throw error }
            }
        }
        guard let ffmpeg = tools.ffmpeg else {
            throw ConversionFailure.toolMissing("Install via \(ExternalTool.ffmpeg.brewInstallLine)")
        }
        if output.family == "gif" {
            try await gif(ffmpeg: ffmpeg, source: source, destination: destination, settings: settings, tools: tools, runner: runner, trim: trim, progress: progress)
            return
        }
        let audioOnly = output.kind == .audio
        let encoders = audioOnly ? [VideoEncoder.libx264] : FFmpegScripts.videoEncoders(output: output, preference: settings.videoCodec)
        let duration = await probeDuration(source: source, tools: tools, runner: runner)
        var lastError = "ffmpeg failed."
        for encoder in encoders {
            let spec = FFmpegScripts.transcode(
                ffmpeg: ffmpeg,
                input: source.path,
                output: destination.path,
                outputType: output,
                encoder: encoder,
                bitrate: FFmpegScripts.bitrateString(mbps: settings.videoBitrateMbps),
                trim: trim,
                audioOnly: audioOnly
            )
            var parser = FFmpegProgressParser(duration: duration)
            let (status, errorText) = try await runner.runWithError(spec) { line in
                progress(parser.ingest(line: line))
            }
            if status == 0 {
                progress(1)
                return
            }
            try? FileManager.default.removeItem(at: destination)
            lastError = errorText.isEmpty ? "ffmpeg exited \(status) using \(encoder.ffmpegCodec)." : errorText
            if runnerWasCancelled(status) { throw ConversionFailure.cancelled }
        }
        throw ConversionFailure.toolFailed(String(lastError.suffix(500)))
    }

    /// WebP/AVIF still: ImageIO decodes (HEIC grids, EXIF orientation), ffmpeg encodes.
    static func still(
        source: URL,
        destination: URL,
        output: FileType,
        quality: Double?,
        tools: ToolAvailability,
        runner: ProcessRunner
    ) async throws {
        guard let ffmpeg = tools.ffmpeg else {
            throw ConversionFailure.toolMissing("Install via \(ExternalTool.ffmpeg.brewInstallLine)")
        }
        let image = try ImageIOBridge.loadOriented(source)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("pith-still-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: staging) }
        try ImageIOBridge.write(image, to: staging, uti: FileTypes.png.uti, quality: nil)
        let spec = FFmpegScripts.still(ffmpeg: ffmpeg, input: staging.path, output: destination.path, outputType: output, quality: quality)
        let (status, errorText) = try await runner.runWithError(spec)
        guard status == 0 else {
            try? FileManager.default.removeItem(at: destination)
            if runnerWasCancelled(status) { throw ConversionFailure.cancelled }
            throw ConversionFailure.toolFailed(errorText.isEmpty ? "ffmpeg couldn't write \(destination.lastPathComponent)." : String(errorText.suffix(500)))
        }
    }

    private static func gif(
        ffmpeg: String,
        source: URL,
        destination: URL,
        settings: PithSettings,
        tools: ToolAvailability,
        runner: ProcessRunner,
        trim: TrimRange?,
        progress: @escaping (Double) -> Void
    ) async throws {
        let palette = FileManager.default.temporaryDirectory.appendingPathComponent("pith-palette-\(UUID().uuidString).png")
        let passes = FFmpegScripts.gif(
            ffmpeg: ffmpeg,
            input: source.path,
            output: destination.path,
            palettePath: palette.path,
            fps: settings.gifFramesPerSecond,
            maxWidth: settings.gifMaxWidth,
            trim: trim
        )
        let duration = await probeDuration(source: source, tools: tools, runner: runner)
        let (first, errorText) = try await runner.runWithError(passes[0])
        guard first == 0 else {
            throw ConversionFailure.toolFailed(errorText.isEmpty ? "GIF palette pass failed." : String(errorText.suffix(400)))
        }
        progress(0.15)
        var parser = FFmpegProgressParser(duration: duration)
        let (second, secondError) = try await runner.runWithError(passes[1]) { line in
            progress(0.15 + 0.85 * parser.ingest(line: line))
        }
        try? FileManager.default.removeItem(at: palette)
        guard second == 0 else {
            throw ConversionFailure.toolFailed(secondError.isEmpty ? "GIF encode failed." : String(secondError.suffix(400)))
        }
    }

    private static func probeDuration(source: URL, tools: ToolAvailability, runner: ProcessRunner) async -> Double {
        guard let ffprobe = tools.ffprobe else { return 0 }
        let spec = FFmpegScripts.probe(ffprobe: ffprobe, input: source.path)
        var text = ""
        let status = try? await runner.run(spec) { line in text += line }
        guard status == 0 else { return 0 }
        return Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private static func runnerWasCancelled(_ status: Int32) -> Bool {
        status == 255 || status == 15
    }
}

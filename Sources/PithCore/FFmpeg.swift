import Foundation

public enum VideoEncoder: String, Equatable, Sendable, Codable {
    case h264VideoToolbox
    case hevcVideoToolbox
    case libx264
    case libx265
    case vp9
    case mpeg4

    public var ffmpegCodec: String {
        switch self {
        case .h264VideoToolbox: return "h264_videotoolbox"
        case .hevcVideoToolbox: return "hevc_videotoolbox"
        case .libx264: return "libx264"
        case .libx265: return "libx265"
        case .vp9: return "libvpx-vp9"
        case .mpeg4: return "mpeg4"
        }
    }

    public var isHardware: Bool {
        switch self {
        case .h264VideoToolbox, .hevcVideoToolbox: return true
        default: return false
        }
    }
}

public struct TrimRange: Equatable, Sendable {
    public var startSeconds: Double
    public var endSeconds: Double?

    public init(startSeconds: Double, endSeconds: Double?) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

public enum FFmpegScripts {
    /// Hardware encoder first, software encoder second. The runner retries the fallback
    /// when videotoolbox is missing or exits non-zero.
    public static func videoEncoders(output: FileType, preference: VideoCodecPreference) -> [VideoEncoder] {
        switch output.family {
        case "webm":
            return [.vp9]
        case "avi":
            return [.mpeg4, .libx264]
        case "gif":
            return []
        default:
            switch preference {
            case .h264:
                return [.h264VideoToolbox, .libx264]
            case .hevc:
                return [.hevcVideoToolbox, .libx265]
            }
        }
    }

    public static func audioArguments(for output: FileType) -> [String] {
        switch output.family {
        case "mp3": return ["-c:a", "libmp3lame", "-q:a", "2"]
        case "m4a": return ["-c:a", "aac", "-b:a", "192k"]
        case "wav": return ["-c:a", "pcm_s16le"]
        case "flac": return ["-c:a", "flac"]
        case "ogg": return ["-c:a", "libvorbis", "-q:a", "5"]
        case "opus": return ["-c:a", "libopus", "-b:a", "128k"]
        case "aiff": return ["-c:a", "pcm_s16be"]
        case "webm": return ["-c:a", "libopus", "-b:a", "128k"]
        case "gif": return ["-an"]
        default: return ["-c:a", "aac", "-b:a", "160k"]
        }
    }

    public static func transcode(
        ffmpeg: String,
        input: String,
        output: String,
        outputType: FileType,
        encoder: VideoEncoder,
        bitrate: String,
        trim: TrimRange? = nil,
        audioOnly: Bool = false
    ) -> CommandSpec {
        var args = ["-y", "-hide_banner", "-nostats"]
        args.append(contentsOf: ["-i", input])
        if let trim {
            args.append(contentsOf: ["-ss", formatSeconds(trim.startSeconds)])
            if let end = trim.endSeconds {
                args.append(contentsOf: ["-to", formatSeconds(end)])
            }
        }
        if audioOnly || outputType.kind == .audio {
            args.append("-vn")
            args.append(contentsOf: audioArguments(for: outputType))
        } else {
            args.append(contentsOf: ["-c:v", encoder.ffmpegCodec])
            if encoder == .vp9 {
                args.append(contentsOf: ["-b:v", bitrate, "-crf", "32"])
            } else if encoder == .libx264 || encoder == .libx265 {
                args.append(contentsOf: ["-b:v", bitrate, "-preset", "medium"])
            } else {
                args.append(contentsOf: ["-b:v", bitrate])
            }
            if encoder == .libx264 || encoder == .h264VideoToolbox {
                args.append(contentsOf: ["-pix_fmt", "yuv420p"])
            }
            args.append(contentsOf: audioArguments(for: outputType))
            if outputType.family == "mp4" || outputType.family == "mov" {
                args.append(contentsOf: ["-movflags", "+faststart"])
            }
        }
        args.append(contentsOf: ["-progress", "pipe:1", output])
        return CommandSpec(executable: ffmpeg, arguments: args, progressOnStdout: true)
    }

    /// Two passes: palettegen, then paletteuse. `palettePath` is a temporary PNG.
    public static func gif(
        ffmpeg: String,
        input: String,
        output: String,
        palettePath: String,
        fps: Int,
        maxWidth: Int,
        trim: TrimRange? = nil
    ) -> [CommandSpec] {
        let filterPrefix = "fps=\(fps),scale=\(maxWidth):-1:flags=lanczos"
        var pass1 = ["-y", "-hide_banner", "-i", input]
        if let trim {
            pass1.append(contentsOf: ["-ss", formatSeconds(trim.startSeconds)])
            if let end = trim.endSeconds {
                pass1.append(contentsOf: ["-to", formatSeconds(end)])
            }
        }
        pass1.append(contentsOf: ["-vf", filterPrefix + ",palettegen", "-frames:v", "1", palettePath])

        // Trim options go before the first `-i` so they apply to that input.
        var pass2 = ["-y", "-hide_banner", "-nostats"]
        if let trim {
            pass2.append(contentsOf: ["-ss", formatSeconds(trim.startSeconds)])
            if let end = trim.endSeconds {
                pass2.append(contentsOf: ["-to", formatSeconds(end)])
            }
        }
        pass2.append(contentsOf: ["-i", input, "-i", palettePath])
        pass2.append(contentsOf: [
            "-lavfi", "\(filterPrefix)[x];[x][1:v]paletteuse",
            "-progress", "pipe:1",
            output
        ])
        return [
            CommandSpec(executable: ffmpeg, arguments: pass1, progressOnStdout: false),
            CommandSpec(executable: ffmpeg, arguments: pass2, progressOnStdout: true)
        ]
    }

    /// Single still image (WebP, AVIF). `input` is a PNG that ImageIO decoded and oriented,
    /// because ffmpeg can't read HEIC grids or apply EXIF orientation.
    public static func still(ffmpeg: String, input: String, output: String, outputType: FileType, quality: Double?) -> CommandSpec {
        var args = ["-y", "-hide_banner", "-v", "error", "-i", input]
        switch outputType.family {
        case "webp":
            let q = Int(((quality ?? 0.8) * 100).rounded())
            args += ["-c:v", "libwebp", "-quality", String(min(100, max(1, q)))]
        case "avif":
            let crf = Int(((1 - (quality ?? 0.6)) * 63).rounded())
            args += ["-c:v", "libaom-av1", "-still-picture", "1", "-crf", String(min(63, max(0, crf)))]
        default:
            break
        }
        args += ["-frames:v", "1", output]
        return CommandSpec(executable: ffmpeg, arguments: args, progressOnStdout: false)
    }

    public static func probe(ffprobe: String, input: String) -> CommandSpec {
        CommandSpec(
            executable: ffprobe,
            arguments: [
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                input
            ],
            progressOnStdout: false
        )
    }

    public static func formatSeconds(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0" }
        return String(format: "%.3f", seconds)
    }

    public static func bitrateString(mbps: Double) -> String {
        let clamped = min(80, max(0.2, mbps))
        if clamped < 1 {
            return String(format: "%.0fk", clamped * 1000)
        }
        return String(format: "%.1fM", clamped)
    }
}

public struct FFmpegProgressParser: Equatable {
    public var duration: Double
    public private(set) var fraction: Double

    public init(duration: Double) {
        self.duration = duration
        self.fraction = 0
    }

    public mutating func ingest(line: String) -> Double {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "progress=end" {
            fraction = 1
            return fraction
        }
        if trimmed.hasPrefix("out_time_us="), let microseconds = Double(trimmed.dropFirst("out_time_us=".count)) {
            fraction = fractionFrom(seconds: microseconds / 1_000_000)
        } else if trimmed.hasPrefix("out_time_ms="), let raw = Double(trimmed.dropFirst("out_time_ms=".count)) {
            // ffmpeg's out_time_ms is microseconds in released builds, despite the name.
            fraction = fractionFrom(seconds: raw / 1_000_000)
        } else if trimmed.hasPrefix("out_time=") {
            let stamp = String(trimmed.dropFirst("out_time=".count))
            if let seconds = Self.parseTimestamp(stamp) {
                fraction = fractionFrom(seconds: seconds)
            }
        }
        return fraction
    }

    public static func parseTimestamp(_ stamp: String) -> Double? {
        let parts = stamp.split(separator: ":")
        guard parts.count == 3, let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2]) else {
            return nil
        }
        return hours * 3600 + minutes * 60 + seconds
    }

    private func fractionFrom(seconds: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, seconds / duration))
    }
}

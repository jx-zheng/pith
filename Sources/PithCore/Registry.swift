public enum ConverterRegistry {
    public static func conversionOffers(for input: FileType, tools: ToolAvailability = .none) -> [ConversionOffer] {
        var offers: [ConversionOffer] = []
        offers.append(contentsOf: imageOffers(for: input, tools: tools))
        offers.append(contentsOf: pdfOffers(for: input, tools: tools))
        offers.append(contentsOf: mediaOffers(for: input, tools: tools))
        offers.append(contentsOf: documentOffers(for: input, tools: tools))
        offers.append(contentsOf: spreadsheetOffers(for: input, tools: tools))
        offers.append(contentsOf: subtitleOffers(for: input))
        offers.append(contentsOf: archiveOffers(for: input))
        let unique = dedupe(offers.filter { $0.output.family != input.family })
        if input.kind == .video {
            return order(unique, preferred: Self.videoLabelOrder)
        }
        return order(unique)
    }

    public static func imageOffers(for input: FileType, tools: ToolAvailability) -> [ConversionOffer] {
        guard input.kind == .image || input.kind == .pdf else { return [] }
        guard input.kind == .image else { return [] }
        let native: [(FileType, ConversionBackend)] = [
            (FileTypes.jpeg, .imageIO),
            (FileTypes.png, .imageIO),
            (FileTypes.heic, .imageIO),
            (FileTypes.tiff, .imageIO),
            (FileTypes.bmp, .imageIO),
            (FileTypes.gif, .imageIO),
            (FileTypes.pdf, .pdfKit)
        ]
        var offers = native.map { type, backend in
            offer(type, backend: backend, enabled: true, reason: nil)
        }
        // WebP and AVIF writes go through ffmpeg. ImageIO is used to read them.
        offers.append(offer(
            FileTypes.webp,
            backend: .ffmpeg,
            enabled: tools.hasFFmpeg,
            reason: tools.hasFFmpeg ? nil : ExternalTool.ffmpeg.brewInstallLine
        ))
        offers.append(offer(
            FileTypes.avif,
            backend: .ffmpeg,
            enabled: tools.hasFFmpeg,
            reason: tools.hasFFmpeg ? nil : ExternalTool.ffmpeg.brewInstallLine
        ))
        return offers
    }

    public static func pdfOffers(for input: FileType, tools: ToolAvailability) -> [ConversionOffer] {
        guard input.kind == .pdf else { return [] }
        var offers = [
            offer(FileTypes.jpeg, backend: .pdfKit, enabled: true, reason: nil),
            offer(FileTypes.png, backend: .pdfKit, enabled: true, reason: nil),
            offer(FileTypes.text, backend: .pdfKit, enabled: true, reason: nil)
        ]
        let docxEnabled = tools.hasSoffice || tools.hasPandoc
        let docxReason = docxEnabled ? nil : "Install via \(ExternalTool.soffice.brewInstallLine)"
        offers.append(offer(
            FileTypes.docx,
            backend: tools.hasPandoc ? .pandoc : .libreOffice,
            enabled: docxEnabled,
            reason: docxReason
        ))
        return offers
    }

    public static func mediaOffers(for input: FileType, tools: ToolAvailability) -> [ConversionOffer] {
        let reason = tools.hasFFmpeg ? nil : "Install via \(ExternalTool.ffmpeg.brewInstallLine)"
        if input.family == "gif" && input.kind == .image {
            let enabled = tools.hasFFmpeg
            return [offer(
                FileTypes.mp4,
                backend: .ffmpeg,
                enabled: enabled,
                reason: enabled ? nil : reason
            )]
        }
        if input.kind == .video {
            let ffmpegRoute = (ConversionBackend.ffmpeg, tools.hasFFmpeg)
            let videoTargets: [(FileType, ConversionBackend, Bool)] = [
                (FileTypes.mp4, route(input: input, output: FileTypes.mp4, tools: tools).0, route(input: input, output: FileTypes.mp4, tools: tools).1),
                (FileTypes.mov, route(input: input, output: FileTypes.mov, tools: tools).0, route(input: input, output: FileTypes.mov, tools: tools).1),
                (FileTypes.mkv, ffmpegRoute.0, ffmpegRoute.1),
                (FileTypes.webm, ffmpegRoute.0, ffmpegRoute.1),
                (FileTypes.avi, ffmpegRoute.0, ffmpegRoute.1),
                (FileTypes.gif, ffmpegRoute.0, ffmpegRoute.1),
                (FileTypes.mp3, ffmpegRoute.0, ffmpegRoute.1),
                (FileTypes.m4a, route(input: input, output: FileTypes.m4a, tools: tools).0, route(input: input, output: FileTypes.m4a, tools: tools).1)
            ]
            return videoTargets.map { type, backend, enabled in
                offer(type, backend: backend, enabled: enabled, reason: enabled ? nil : reason)
            }
        }
        if input.kind == .audio {
            let audio: [FileType] = [
                FileTypes.mp3, FileTypes.m4a, FileTypes.wav, FileTypes.flac,
                FileTypes.ogg, FileTypes.opus, FileTypes.aiff
            ]
            return audio.map { type in
                let backend: ConversionBackend = (type.family == "m4a" && isAppleAudioContainer(input)) ? .avFoundation : .ffmpeg
                let enabled = backend == .avFoundation || tools.hasFFmpeg
                return offer(type, backend: backend, enabled: enabled, reason: enabled ? nil : reason)
            }
        }
        return []
    }

    public static func documentOffers(for input: FileType, tools: ToolAvailability) -> [ConversionOffer] {
        let pandocTypes: Set<String> = ["docx", "markdown", "html", "epub", "text", "rtf"]
        guard pandocTypes.contains(input.family) || input.kind == .presentation else { return [] }

        if input.kind == .presentation {
            let enabled = tools.hasSoffice
            return [offer(
                FileTypes.pdf,
                backend: .libreOffice,
                enabled: enabled,
                reason: enabled ? nil : "Install via \(ExternalTool.soffice.brewInstallLine)"
            )]
        }

        let targets = [FileTypes.docx, FileTypes.markdown, FileTypes.html, FileTypes.epub, FileTypes.text, FileTypes.rtf]
        return targets.map { target in
            if tools.hasPandoc {
                return offer(target, backend: .pandoc, enabled: true, reason: nil)
            }
            if nativeDocumentFallback(from: input, to: target) {
                return offer(target, backend: .attributedString, enabled: true, reason: nil)
            }
            return offer(
                target,
                backend: .pandoc,
                enabled: false,
                reason: "Install via \(ExternalTool.pandoc.brewInstallLine)"
            )
        }
    }

    public static func spreadsheetOffers(for input: FileType, tools: ToolAvailability) -> [ConversionOffer] {
        switch input.family {
        case "csv":
            return [offer(FileTypes.tsv, backend: .csv, enabled: true, reason: nil)]
        case "tsv":
            return [offer(FileTypes.csv, backend: .csv, enabled: true, reason: nil)]
        case "xlsx", "xls", "ods":
            var offers: [ConversionOffer] = []
            let pdfEnabled = tools.hasSoffice
            offers.append(offer(
                FileTypes.pdf,
                backend: .libreOffice,
                enabled: pdfEnabled,
                reason: pdfEnabled ? nil : "Install via \(ExternalTool.soffice.brewInstallLine)"
            ))
            let csvEnabled = tools.hasSoffice
            offers.append(offer(
                FileTypes.csv,
                backend: .libreOffice,
                enabled: csvEnabled,
                reason: csvEnabled ? nil : "Install via \(ExternalTool.soffice.brewInstallLine)"
            ))
            if input.family != "ods" {
                offers.append(offer(
                    FileTypes.ods,
                    backend: .libreOffice,
                    enabled: tools.hasSoffice,
                    reason: tools.hasSoffice ? nil : "Install via \(ExternalTool.soffice.brewInstallLine)"
                ))
            }
            if input.family == "ods" {
                offers.append(offer(
                    FileTypes.xlsx,
                    backend: .libreOffice,
                    enabled: tools.hasSoffice,
                    reason: tools.hasSoffice ? nil : "Install via \(ExternalTool.soffice.brewInstallLine)"
                ))
            }
            return offers
        default:
            return []
        }
    }

    public static func subtitleOffers(for input: FileType) -> [ConversionOffer] {
        switch input.family {
        case "srt":
            return [offer(FileTypes.vtt, backend: .subtitles, enabled: true, reason: nil)]
        case "vtt":
            return [offer(FileTypes.srt, backend: .subtitles, enabled: true, reason: nil)]
        default:
            return []
        }
    }

    public static func archiveOffers(for input: FileType) -> [ConversionOffer] {
        if input.kind == .folder {
            return [
                offer(FileTypes.zip, backend: .archive, enabled: true, reason: nil),
                offer(FileTypes.gzip, backend: .archive, enabled: true, reason: nil)
            ]
        }
        switch input.family {
        case "zip":
            return [offer(FileTypes.folder, backend: .archive, enabled: true, reason: nil, id: "unzip", label: "UNZIP")]
        case "tar", "gzip":
            return [offer(FileTypes.folder, backend: .archive, enabled: true, reason: nil, id: "untar", label: "EXTRACT")]
        case _ where input.kind == .document || input.kind == .spreadsheet || input.kind == .presentation || input.kind == .subtitle || input.kind == .other:
            return [
                offer(FileTypes.zip, backend: .archive, enabled: true, reason: nil),
                offer(FileTypes.gzip, backend: .archive, enabled: true, reason: nil)
            ]
        default:
            // Images, video, audio, and PDF keep the reference wheel uncluttered.
            return []
        }
    }

    /// NSAttributedString can round-trip these without pandoc. DOCX read/write is included
    /// because AppKit's officeOpenXML document type covers it; pandoc is still preferred.
    public static func nativeDocumentFallback(from input: FileType, to output: FileType) -> Bool {
        let supported: Set<String> = ["text", "rtf", "html", "docx"]
        return supported.contains(input.family) && supported.contains(output.family)
    }

    public static let videoLabelOrder = ["MP4", "MOV", "MKV", "WEBM", "AVI", "GIF", "MP3", "M4A"]

    public static func order(_ offers: [ConversionOffer], preferred: [String] = FileTypes.formatLabelOrder) -> [ConversionOffer] {
        offers.sorted { lhs, rhs in
            let li = preferred.firstIndex(of: lhs.label) ?? Int.max
            let ri = preferred.firstIndex(of: rhs.label) ?? Int.max
            if li != ri { return li < ri }
            return lhs.label < rhs.label
        }
    }

    private static func dedupe(_ offers: [ConversionOffer]) -> [ConversionOffer] {
        var seen = Set<String>()
        var result: [ConversionOffer] = []
        for offer in offers where seen.insert(offer.id).inserted {
            result.append(offer)
        }
        return result
    }

    private static func offer(
        _ type: FileType,
        backend: ConversionBackend,
        enabled: Bool,
        reason: String?,
        id: String? = nil,
        label: String? = nil
    ) -> ConversionOffer {
        ConversionOffer(
            id: id ?? "to-\(type.label.lowercased())",
            label: label ?? type.label,
            output: type,
            backend: backend,
            isEnabled: enabled,
            unavailableReason: reason
        )
    }

    private static func route(
        input: FileType,
        output: FileType,
        tools: ToolAvailability
    ) -> (ConversionBackend, Bool) {
        if MediaRouter.prefersAVFoundation(input: input, output: output) {
            return (.avFoundation, true)
        }
        return (.ffmpeg, tools.hasFFmpeg)
    }

    private static func isAppleAudioContainer(_ type: FileType) -> Bool {
        type.family == "mp4" || type.family == "mov" || type.family == "m4a"
    }
}

public enum MediaRouter {
    /// Apple-native containers where AVAssetExportSession is enough.
    public static func prefersAVFoundation(input: FileType, output: FileType) -> Bool {
        let appleVideo: Set<String> = ["mp4", "mov"]
        if appleVideo.contains(input.family) && appleVideo.contains(output.family) { return true }
        if appleVideo.contains(input.family) && output.family == "m4a" { return true }
        if input.family == "m4a" && output.family == "m4a" { return false }
        return false
    }
}

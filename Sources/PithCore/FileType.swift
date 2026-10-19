public struct FileType: Equatable, Hashable, Sendable, Codable, Identifiable {
    public var uti: String
    public var extensions: [String]
    public var label: String
    /// Formats that should not be offered as a conversion of each other (jpg/jpeg).
    public var family: String
    public var kind: FileKind

    public var id: String { uti }

    public init(uti: String, extensions: [String], label: String, family: String, kind: FileKind) {
        self.uti = uti
        self.extensions = extensions
        self.label = label
        self.family = family
        self.kind = kind
    }
}

public enum FileKind: String, Codable, Sendable, Equatable {
    case image
    case pdf
    case video
    case audio
    case document
    case spreadsheet
    case presentation
    case subtitle
    case archive
    case folder
    case other
}

public enum FileTypes {
    public static let jpeg = FileType(uti: "public.jpeg", extensions: ["jpg", "jpeg"], label: "JPG", family: "jpeg", kind: .image)
    public static let png = FileType(uti: "public.png", extensions: ["png"], label: "PNG", family: "png", kind: .image)
    public static let heic = FileType(uti: "public.heic", extensions: ["heic", "heif"], label: "HEIC", family: "heic", kind: .image)
    public static let tiff = FileType(uti: "public.tiff", extensions: ["tif", "tiff"], label: "TIFF", family: "tiff", kind: .image)
    public static let bmp = FileType(uti: "com.microsoft.bmp", extensions: ["bmp"], label: "BMP", family: "bmp", kind: .image)
    public static let gif = FileType(uti: "com.compuserve.gif", extensions: ["gif"], label: "GIF", family: "gif", kind: .image)
    public static let webp = FileType(uti: "org.webmproject.webp", extensions: ["webp"], label: "WEBP", family: "webp", kind: .image)
    public static let avif = FileType(uti: "public.avif", extensions: ["avif"], label: "AVIF", family: "avif", kind: .image)

    public static let pdf = FileType(uti: "com.adobe.pdf", extensions: ["pdf"], label: "PDF", family: "pdf", kind: .pdf)

    public static let mp4 = FileType(uti: "public.mpeg-4", extensions: ["mp4", "m4v"], label: "MP4", family: "mp4", kind: .video)
    public static let mov = FileType(uti: "com.apple.quicktime-movie", extensions: ["mov"], label: "MOV", family: "mov", kind: .video)
    public static let mkv = FileType(uti: "org.matroska.mkv", extensions: ["mkv"], label: "MKV", family: "mkv", kind: .video)
    public static let webm = FileType(uti: "org.webmproject.webm", extensions: ["webm"], label: "WEBM", family: "webm", kind: .video)
    public static let avi = FileType(uti: "public.avi", extensions: ["avi"], label: "AVI", family: "avi", kind: .video)

    public static let mp3 = FileType(uti: "public.mp3", extensions: ["mp3"], label: "MP3", family: "mp3", kind: .audio)
    public static let m4a = FileType(uti: "public.mpeg-4-audio", extensions: ["m4a"], label: "M4A", family: "m4a", kind: .audio)
    public static let wav = FileType(uti: "com.microsoft.waveform-audio", extensions: ["wav"], label: "WAV", family: "wav", kind: .audio)
    public static let flac = FileType(uti: "org.xiph.flac", extensions: ["flac"], label: "FLAC", family: "flac", kind: .audio)
    public static let ogg = FileType(uti: "org.xiph.ogg-vorbis", extensions: ["ogg", "oga"], label: "OGG", family: "ogg", kind: .audio)
    public static let opus = FileType(uti: "org.xiph.opus", extensions: ["opus"], label: "OPUS", family: "opus", kind: .audio)
    public static let aiff = FileType(uti: "public.aiff-audio", extensions: ["aiff", "aif"], label: "AIFF", family: "aiff", kind: .audio)

    public static let docx = FileType(uti: "org.openxmlformats.wordprocessingml.document", extensions: ["docx"], label: "DOCX", family: "docx", kind: .document)
    public static let markdown = FileType(uti: "net.daringfireball.markdown", extensions: ["md", "markdown"], label: "MD", family: "markdown", kind: .document)
    public static let html = FileType(uti: "public.html", extensions: ["html", "htm"], label: "HTML", family: "html", kind: .document)
    public static let epub = FileType(uti: "org.idpf.epub-container", extensions: ["epub"], label: "EPUB", family: "epub", kind: .document)
    public static let text = FileType(uti: "public.plain-text", extensions: ["txt"], label: "TXT", family: "text", kind: .document)
    public static let rtf = FileType(uti: "public.rtf", extensions: ["rtf"], label: "RTF", family: "rtf", kind: .document)

    public static let pptx = FileType(uti: "org.openxmlformats.presentationml.presentation", extensions: ["pptx"], label: "PPTX", family: "pptx", kind: .presentation)
    public static let ppt = FileType(uti: "com.microsoft.powerpoint.ppt", extensions: ["ppt"], label: "PPT", family: "ppt", kind: .presentation)
    public static let xlsx = FileType(uti: "org.openxmlformats.spreadsheetml.sheet", extensions: ["xlsx"], label: "XLSX", family: "xlsx", kind: .spreadsheet)
    public static let xls = FileType(uti: "com.microsoft.excel.xls", extensions: ["xls"], label: "XLS", family: "xls", kind: .spreadsheet)
    public static let ods = FileType(uti: "org.oasis-open.opendocument.spreadsheet", extensions: ["ods"], label: "ODS", family: "ods", kind: .spreadsheet)
    public static let csv = FileType(uti: "public.comma-separated-values-text", extensions: ["csv"], label: "CSV", family: "csv", kind: .spreadsheet)
    public static let tsv = FileType(uti: "public.tab-separated-values-text", extensions: ["tsv"], label: "TSV", family: "tsv", kind: .spreadsheet)

    public static let srt = FileType(uti: "public.srt", extensions: ["srt"], label: "SRT", family: "srt", kind: .subtitle)
    public static let vtt = FileType(uti: "public.vtt", extensions: ["vtt"], label: "VTT", family: "vtt", kind: .subtitle)

    public static let zip = FileType(uti: "public.zip-archive", extensions: ["zip"], label: "ZIP", family: "zip", kind: .archive)
    public static let tar = FileType(uti: "public.tar-archive", extensions: ["tar"], label: "TAR", family: "tar", kind: .archive)
    public static let gzip = FileType(uti: "org.gnu.gnu-zip-archive", extensions: ["gz", "tgz"], label: "GZIP", family: "gzip", kind: .archive)

    public static let folder = FileType(uti: "public.folder", extensions: [], label: "FOLDER", family: "folder", kind: .folder)

    public static let catalog: [FileType] = [
        jpeg, png, heic, tiff, bmp, gif, webp, avif,
        pdf,
        mp4, mov, mkv, webm, avi,
        mp3, m4a, wav, flac, ogg, opus, aiff,
        docx, markdown, html, epub, text, rtf,
        pptx, ppt, xlsx, xls, ods, csv, tsv,
        srt, vtt,
        zip, tar, gzip,
        folder
    ]

    /// Clockwise from the top of the wheel. The first remaining label sits at 12 o'clock.
    public static let formatLabelOrder: [String] = [
        "DOCX", "JPG", "PNG", "TXT", "WEBP", "HEIC", "TIFF", "AVIF", "BMP", "PDF", "GIF",
        "MD", "HTML", "EPUB", "RTF",
        "MP4", "MOV", "MKV", "WEBM", "AVI",
        "MP3", "M4A", "WAV", "FLAC", "OGG", "OPUS", "AIFF",
        "PPTX", "PPT", "XLSX", "XLS", "ODS", "CSV", "TSV",
        "SRT", "VTT", "ZIP", "TAR", "GZIP"
    ]

    public static func matching(pathExtension: String) -> FileType? {
        let ext = pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return catalog.first { $0.extensions.contains(ext) }
    }

    public static func matching(uti: String) -> FileType? {
        let needle = uti.lowercased()
        if let exact = catalog.first(where: { $0.uti.lowercased() == needle }) {
            return exact
        }
        // Promised types sometimes arrive as a more specific UTI. Match a known suffix.
        return catalog.first { needle.contains($0.uti.lowercased()) }
    }

    public static func matching(path: String) -> FileType? {
        let ext = path.split(separator: ".").last.map(String.init) ?? ""
        // "archive.tar.gz" should resolve as gzip, not a bare "gz" miss.
        let lower = path.lowercased()
        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") {
            return gzip
        }
        return matching(pathExtension: ext)
    }
}

extension FileType {
    public var primaryExtension: String { extensions.first ?? "bin" }

    public var isRasterImage: Bool { kind == .image }
}

import Foundation

public enum CSVTSV {
    public static func convert(text: String, toTSV: Bool) -> String {
        let source: Character = toTSV ? "," : "\t"
        let rows = parse(text, separator: source)
        return render(rows, separator: toTSV ? "\t" : ",")
    }

    public static func parse(_ text: String, separator: Character = ",") -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let scalars = Array(text)
        var index = 0
        while index < scalars.count {
            let character = scalars[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < scalars.count && scalars[index + 1] == "\"" {
                        field.append("\"")
                        index += 2
                        continue
                    }
                    inQuotes = false
                    index += 1
                    continue
                }
                field.append(character)
                index += 1
                continue
            }
            if character == "\"" && field.isEmpty {
                inQuotes = true
                index += 1
                continue
            }
            if character == separator {
                row.append(field)
                field = ""
                index += 1
                continue
            }
            if character == "\n" || character == "\r" {
                if character == "\r" && index + 1 < scalars.count && scalars[index + 1] == "\n" {
                    index += 1
                }
                row.append(field)
                field = ""
                if !(row.count == 1 && row[0].isEmpty && rows.isEmpty) {
                    rows.append(row)
                } else if rows.isEmpty && row == [""] {
                    rows.append(row)
                } else {
                    rows.append(row)
                }
                row = []
                index += 1
                continue
            }
            field.append(character)
            index += 1
        }
        if inQuotes || !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    public static func render(_ rows: [[String]], separator: String) -> String {
        rows.map { row in
            row.map { escape($0, separator: separator) }.joined(separator: separator)
        }.joined(separator: "\n")
    }

    private static func escape(_ field: String, separator: String) -> String {
        if field.contains(separator) || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }
}

public struct SubtitleCue: Equatable, Sendable {
    public var identifier: String?
    public var start: String
    public var end: String
    public var text: String

    public init(identifier: String?, start: String, end: String, text: String) {
        self.identifier = identifier
        self.start = start
        self.end = end
        self.text = text
    }
}

public enum Subtitles {
    public static func srtToVTT(_ srt: String) -> String {
        let cues = parseSRT(srt)
        var lines = ["WEBVTT", ""]
        for cue in cues {
            if let identifier = cue.identifier, !identifier.isEmpty {
                lines.append(identifier)
            }
            lines.append("\(dot(cue.start)) --> \(dot(cue.end))")
            lines.append(cue.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public static func vttToSRT(_ vtt: String) -> String {
        let cues = parseVTT(vtt)
        var blocks: [String] = []
        for (index, cue) in cues.enumerated() {
            let number = cue.identifier.flatMap(Int.init) ?? (index + 1)
            blocks.append("\(number)\n\(comma(cue.start)) --> \(comma(cue.end))\n\(cue.text)")
        }
        return blocks.joined(separator: "\n\n") + (blocks.isEmpty ? "" : "\n")
    }

    public static func parseSRT(_ text: String) -> [SubtitleCue] {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        var cues: [SubtitleCue] = []
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timing = lines[timingIndex]
            let parts = timing.components(separatedBy: "-->")
            guard parts.count >= 2 else { continue }
            let start = parts[0].trimmingCharacters(in: .whitespaces)
            let end = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
            let body = lines.dropFirst(timingIndex + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let identifier = timingIndex > 0 ? lines[0] : nil
            guard !body.isEmpty || !start.isEmpty else { continue }
            cues.append(SubtitleCue(identifier: identifier, start: start, end: end, text: body))
        }
        return cues
    }

    public static func parseVTT(_ text: String) -> [SubtitleCue] {
        var body = text.replacingOccurrences(of: "\r\n", with: "\n")
        if body.hasPrefix("WEBVTT") {
            if let range = body.range(of: "\n\n") {
                body = String(body[range.upperBound...])
            } else {
                body = ""
            }
        }
        return parseSRT(body)
    }

    private static func dot(_ timestamp: String) -> String { timestamp.replacingOccurrences(of: ",", with: ".") }
    private static func comma(_ timestamp: String) -> String { timestamp.replacingOccurrences(of: ".", with: ",") }
}

public final class CSVConverter: Converter {
    public let id = "csv"
    public let inputTypes = [FileTypes.csv, FileTypes.tsv]
    public let outputTypes = [FileTypes.csv, FileTypes.tsv]

    public init() {}

    public func run(source: URL, destination: URL, context: ConversionContext) async throws -> [URL] {
        let text = try String(contentsOf: source, encoding: .utf8)
        let toTSV = destination.pathExtension.lowercased() == "tsv"
        let converted = CSVTSV.convert(text: text, toTSV: toTSV)
        try converted.write(to: destination, atomically: true, encoding: .utf8)
        context.progress(1)
        return [destination]
    }
}

public final class SubtitleConverter: Converter {
    public let id = "subtitles"
    public let inputTypes = [FileTypes.srt, FileTypes.vtt]
    public let outputTypes = [FileTypes.srt, FileTypes.vtt]

    public init() {}

    public func run(source: URL, destination: URL, context: ConversionContext) async throws -> [URL] {
        let text = try String(contentsOf: source, encoding: .utf8)
        let ext = destination.pathExtension.lowercased()
        let converted: String
        if ext == "vtt" {
            converted = Subtitles.srtToVTT(text)
        } else if ext == "srt" {
            converted = Subtitles.vttToSRT(text)
        } else {
            throw ConversionFailure.unsupported("Subtitles convert between SRT and VTT.")
        }
        try converted.write(to: destination, atomically: true, encoding: .utf8)
        context.progress(1)
        return [destination]
    }
}

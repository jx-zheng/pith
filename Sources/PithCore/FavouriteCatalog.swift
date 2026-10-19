/// A titled run of favourite options, used as a section in the Settings picker.
public struct FavouriteGroup: Equatable, Sendable {
    public var title: String
    public var labels: [String]

    public init(title: String, labels: [String]) {
        self.title = title
        self.labels = labels
    }
}

/// Every segment label a wheel can ever show, derived from the registries.
/// Settings builds its double-tap favourite pickers from this.
public enum FavouriteCatalog {
    /// Tool availability with every external tool present, so no offer is hidden.
    static let everyTool = ToolAvailability(ffmpeg: "ffmpeg", ffprobe: "ffprobe", pandoc: "pandoc", soffice: "soffice")

    /// Inputs the Tools wheel distinguishes: each type alone, two of a type, and a mixed image + PDF drop.
    static var toolInputSets: [[FileType]] {
        var sets: [[FileType]] = []
        for type in FileTypes.catalog {
            sets.append([type])
            sets.append([type, type])
        }
        sets.append([FileTypes.png, FileTypes.pdf])
        return sets
    }

    public static func groups(for kind: WheelKind) -> [FavouriteGroup] {
        switch kind {
        case .convert:
            return convertGroups()
        case .tools:
            return [FavouriteGroup(title: "Tools", labels: toolLabels())]
        case .actions:
            return [FavouriteGroup(title: "Actions", labels: ToolRegistry.actions().map(\.label))]
        }
    }

    public static func labels(for kind: WheelKind) -> [String] {
        groups(for: kind).flatMap(\.labels)
    }

    /// Union of conversion target labels over every catalog input type, with and without tools.
    static func convertGroups() -> [FavouriteGroup] {
        var byGroup: [String: Set<String>] = [:]
        for input in FileTypes.catalog {
            for tools in [everyTool, ToolAvailability.none] {
                for offer in ConverterRegistry.conversionOffers(for: input, tools: tools) {
                    byGroup[groupTitle(for: offer), default: []].insert(offer.label)
                }
            }
        }
        return groupOrder.compactMap { title in
            guard let labels = byGroup[title], !labels.isEmpty else { return nil }
            return FavouriteGroup(title: title, labels: sortLabels(Array(labels)))
        }
    }

    static func toolLabels() -> [String] {
        var seen = Set<ToolID>()
        for inputs in toolInputSets {
            for tools in [everyTool, ToolAvailability.none] {
                for offer in ToolRegistry.tools(for: inputs, tools: tools, fileCount: inputs.count) {
                    seen.insert(offer.tool)
                }
            }
        }
        // Keep the wheel's own order.
        return ToolID.allCases.filter(seen.contains).map(\.label)
    }

    static let groupOrder = ["Images", "Documents", "Video", "Audio", "Spreadsheets", "Subtitles", "Archives"]

    static func groupTitle(for offer: ConversionOffer) -> String {
        switch offer.output.kind {
        case .image: return "Images"
        case .pdf, .document, .presentation: return "Documents"
        case .video: return "Video"
        case .audio: return "Audio"
        case .spreadsheet: return "Spreadsheets"
        case .subtitle: return "Subtitles"
        case .archive, .folder, .other: return "Archives"
        }
    }

    /// Wheel order (`FileTypes.formatLabelOrder`) first, then alphabetical.
    static func sortLabels(_ labels: [String]) -> [String] {
        let order = FileTypes.formatLabelOrder
        return labels.sorted { lhs, rhs in
            let li = order.firstIndex(of: lhs) ?? Int.max
            let ri = order.firstIndex(of: rhs) ?? Int.max
            if li != ri { return li < ri }
            return lhs < rhs
        }
    }
}

import Foundation
import PithCore
import UniformTypeIdentifiers

struct WheelSegmentModel: Identifiable, Equatable {
    var id: String
    var title: String
    var symbol: String?
    var enabled: Bool
    var help: String?
}

enum WheelContents {
    struct Built {
        var segments: [WheelSegmentModel]
        var offers: [ConversionOffer]
        var tools: [ToolOffer]
        var actions: [FileActionID]
        var centerFallback: String
    }

    static func build(kind: WheelKind, session: DragSession, availability: ToolAvailability) -> Built {
        let types = fileTypes(in: session)
        let fallback = centerFallback(session)
        switch kind {
        case .convert:
            let offers = commonOffers(types, availability: availability)
            let segments = offers.map {
                WheelSegmentModel(id: $0.id, title: $0.label, symbol: nil, enabled: $0.isEnabled, help: $0.unavailableReason)
            }
            return Built(segments: segments, offers: offers, tools: [], actions: [], centerFallback: fallback)
        case .tools:
            let toolOffers = ToolRegistry.tools(for: types, tools: availability, fileCount: max(session.filePaths.count, types.count))
            let segments = toolOffers.map {
                WheelSegmentModel(id: $0.id, title: $0.tool.label, symbol: $0.tool.symbolName, enabled: $0.isEnabled, help: $0.unavailableReason)
            }
            return Built(segments: segments, offers: [], tools: toolOffers, actions: [], centerFallback: fallback)
        case .actions:
            let actions = ToolRegistry.actions()
            let segments = actions.map {
                WheelSegmentModel(id: $0.rawValue, title: $0.label, symbol: $0.symbolName, enabled: true, help: nil)
            }
            return Built(segments: segments, offers: [], tools: [], actions: actions, centerFallback: fallback)
        }
    }

    static func fileTypes(in session: DragSession) -> [FileType] {
        if !session.filePaths.isEmpty {
            return session.filePaths.map(resolvePath)
        }
        let promised = session.promisedTypeIdentifiers.compactMap(resolveUTI)
        return promised
    }

    static func resolvePath(_ path: String) -> FileType {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            return FileTypes.folder
        }
        if let matched = FileTypes.matching(path: path) { return matched }
        let ext = URL(fileURLWithPath: path).pathExtension
        if let ut = UTType(filenameExtension: ext) {
            if let matched = FileTypes.matching(uti: ut.identifier) { return matched }
            if ut.conforms(to: .image) { return FileTypes.jpeg }
            if ut.conforms(to: .movie) || ut.conforms(to: .video) { return FileTypes.mp4 }
            if ut.conforms(to: .audio) { return FileTypes.m4a }
            if ut.conforms(to: .pdf) { return FileTypes.pdf }
        }
        return FileType(uti: "public.data", extensions: [ext], label: ext.uppercased(), family: ext.lowercased(), kind: .other)
    }

    static func resolveUTI(_ identifier: String) -> FileType? {
        if let matched = FileTypes.matching(uti: identifier) { return matched }
        guard let ut = UTType(identifier) else { return nil }
        if ut.conforms(to: .image) { return FileTypes.jpeg }
        if ut.conforms(to: .movie) || ut.conforms(to: .video) { return FileTypes.mp4 }
        if ut.conforms(to: .pdf) { return FileTypes.pdf }
        if ut.conforms(to: .audio) { return FileTypes.m4a }
        return nil
    }

    static func centerFallback(_ session: DragSession) -> String {
        if session.filePaths.count > 1 { return "\(session.filePaths.count) FILES" }
        if session.filePaths.isEmpty && session.hasFilePromise { return "FILE" }
        guard let path = session.filePaths.first else { return "" }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        if let number = attributes?[.size] as? NSNumber {
            return ByteCountFormat.string(bytes: number.int64Value)
        }
        return URL(fileURLWithPath: path).pathExtension.uppercased()
    }

    private static func commonOffers(_ types: [FileType], availability: ToolAvailability) -> [ConversionOffer] {
        guard let first = types.first else { return [] }
        var offers = ConverterRegistry.conversionOffers(for: first, tools: availability)
        for type in types.dropFirst() {
            let labels = Set(ConverterRegistry.conversionOffers(for: type, tools: availability).map(\.label))
            offers = offers.filter { labels.contains($0.label) }
        }
        return offers
    }
}

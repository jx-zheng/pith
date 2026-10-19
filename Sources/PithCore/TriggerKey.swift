public enum TriggerKey: String, Codable, Sendable, CaseIterable, Equatable, Hashable {
    case shift
    case command
    case control
    case option
}

public struct ModifierFlags: OptionSet, Equatable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let shift = ModifierFlags(rawValue: 1 << 0)
    public static let command = ModifierFlags(rawValue: 1 << 1)
    public static let control = ModifierFlags(rawValue: 1 << 2)
    public static let option = ModifierFlags(rawValue: 1 << 3)

    public var triggerKeys: Set<TriggerKey> {
        var keys = Set<TriggerKey>()
        if contains(.shift) { keys.insert(.shift) }
        if contains(.command) { keys.insert(.command) }
        if contains(.control) { keys.insert(.control) }
        if contains(.option) { keys.insert(.option) }
        return keys
    }

    public static func flags(for key: TriggerKey) -> ModifierFlags {
        switch key {
        case .shift: return .shift
        case .command: return .command
        case .control: return .control
        case .option: return .option
        }
    }
}

public enum WheelKind: String, Codable, Sendable, Equatable, CaseIterable {
    case convert
    case tools
    case actions
}

public struct KeyBindings: Equatable, Sendable, Codable {
    public var convert: TriggerKey
    public var tools: TriggerKey
    public var actions: TriggerKey
    public var tapMaxDuration: Double

    public init(convert: TriggerKey, tools: TriggerKey, actions: TriggerKey, tapMaxDuration: Double) {
        self.convert = convert
        self.tools = tools
        self.actions = actions
        self.tapMaxDuration = tapMaxDuration
    }

    public static let `default` = KeyBindings(
        convert: .shift,
        tools: .command,
        actions: .control,
        tapMaxDuration: 0.30
    )

    public func wheel(for key: TriggerKey) -> WheelKind? {
        if key == convert { return .convert }
        if key == tools { return .tools }
        if key == actions { return .actions }
        return nil
    }

    public var hasDuplicateKeys: Bool {
        Set([convert, tools, actions]).count < 3
    }
}

public enum MonitorKey: Equatable, Sendable {
    case escape
    case `return`
    case left
    case right
    case up
    case down
    case number(Int)
    case other
}

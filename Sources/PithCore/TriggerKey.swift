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

    /// Next menu when Shift is tapped while a wheel is already open.
    /// Order is convert → tools → actions → convert.
    public var next: WheelKind {
        switch self {
        case .convert: return .tools
        case .tools: return .actions
        case .actions: return .convert
        }
    }
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

    private enum CodingKeys: String, CodingKey {
        case convert, tools, actions, tapMaxDuration
    }

    /// Old settings still carry per-wheel keys. A missing or unknown value falls
    /// back to the default so one bad field does not discard the whole file.
    /// Opening ignores these keys; `tapMaxDuration` is the field that still applies.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        convert = Self.triggerKey(in: container, forKey: .convert, fallback: .shift)
        tools = Self.triggerKey(in: container, forKey: .tools, fallback: .command)
        actions = Self.triggerKey(in: container, forKey: .actions, fallback: .control)
        tapMaxDuration = (try? container.decode(Double.self, forKey: .tapMaxDuration)) ?? Self.default.tapMaxDuration
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(convert, forKey: .convert)
        try container.encode(tools, forKey: .tools)
        try container.encode(actions, forKey: .actions)
        try container.encode(tapMaxDuration, forKey: .tapMaxDuration)
    }

    private static func triggerKey(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys,
        fallback: TriggerKey
    ) -> TriggerKey {
        guard let raw = try? container.decode(String.self, forKey: key) else { return fallback }
        return TriggerKey(rawValue: raw) ?? fallback
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

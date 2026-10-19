/// Detects a modifier tap: press then release, no other modifier or key, within `maxDuration`.
public struct TapDetector: Equatable {
    public var maxDuration: Double
    private var pressedAt: [TriggerKey: Double]
    private var contaminated: Set<TriggerKey>

    public init(maxDuration: Double = 0.30) {
        self.maxDuration = maxDuration
        self.pressedAt = [:]
        self.contaminated = []
    }

    public var isHolding: Bool { !pressedAt.isEmpty }

    public mutating func reset() {
        pressedAt.removeAll()
        contaminated.removeAll()
    }

    /// Marks every in-progress press as not a tap. Used when another key goes down.
    public mutating func contaminateAll() {
        for key in pressedAt.keys {
            contaminated.insert(key)
        }
    }

    /// Returns the key that completed a clean tap on this flags change, if any.
    public mutating func flagsChanged(time: Double, flags: ModifierFlags) -> TriggerKey? {
        let down = flags.triggerKeys
        var tapped: TriggerKey?

        for key in TriggerKey.allCases {
            let isDown = down.contains(key)
            if isDown {
                if pressedAt[key] == nil {
                    pressedAt[key] = time
                    if down.count > 1 {
                        contaminated.insert(key)
                    }
                }
            } else if let start = pressedAt.removeValue(forKey: key) {
                let bad = contaminated.contains(key)
                contaminated.remove(key)
                let duration = time - start
                if !bad && duration >= 0 && duration <= maxDuration && down.isEmpty {
                    tapped = key
                }
            }
        }

        if down.count > 1 {
            for key in down {
                contaminated.insert(key)
            }
        }
        return tapped
    }
}

import Foundation

public enum RingPresence: Equatable, Sendable {
    case hidden
    /// Opened from a Finder selection. The mouse button is already up.
    case click
    /// Opened during a file drag. `buttonDown` is false while a drop grace is pending.
    case drag(buttonDown: Bool)
    /// A non-action dismiss is fading out. Input is already off. `resume` is what
    /// a Shift press restores, at full opacity, without waiting for the fade.
    case closing(resume: RingResume)
}

public enum RingResume: Equatable, Sendable {
    case click
    case drag(buttonDown: Bool)
}

public enum RingPointerButton: Equatable, Sendable {
    case left
    case right
    case other
}

public enum RingDismissEvent: Equatable, Sendable {
    case escape
    case mouseDown(RingPointerButton, onActionableWedge: Bool)
    case mouseUp(RingPointerButton, onActionableWedge: Bool)
    /// A poll saw the drag button up. `pointerInsideRing` is the panel, not a wedge hit.
    case buttonsReleased(pointerInsideRing: Bool)
    case shift(canCycle: Bool)
    case appDeactivated
    case spaceChanged
    /// A new open arrived while a ring is already on screen.
    case openWhileVisible
    case dropAccepted
    /// The drop grace elapsed and no drop landed.
    case dropGraceExpired
    /// The close animation finished, or its fallback timer fired.
    case closeFinished
}

public enum RingDismissDecision: Equatable, Sendable {
    case ignore
    case cycle
    /// Start the short close. The panel stays up until `closeFinished`.
    case beginClose(reason: String)
    /// Animation completion or the fallback timer. Order the panel out.
    case finishClose
    /// Shift (or a new open) cancelled the fade. The same panel is interactive again.
    case reopen
    /// An action dismiss. No fade; the panel is hidden now.
    case dismiss(reason: String)
    /// Keep the ring up briefly so a drop on a wedge can land, then dismiss.
    case dismissAfterDropGrace(reason: String)
    /// A new open while one is visible. The caller reuses the panel; do not fade.
    case replace(reason: String)
}

/// How long a non-action dismiss takes, and the backup that orders the panel out
/// even if the animation completion never runs.
public enum RingCloseTiming {
    public static let duration: Double = 0.12
    public static let fallback: Double = 0.15
}

/// What to do with a ring that may already be on screen.
///
/// The gesture machine can miss the mouse-up that ends a Finder drag (that
/// event is delivered inside Finder's drag loop). This machine still dismisses:
/// a later mouse-down, a poll that sees the button up, Escape, a Shift that
/// cannot cycle, deactivate, or a space change. A second open while one is
/// visible replaces it instead of leaving the old panel up.
///
/// Click-away and other non-action dismisses enter `.closing`. Clicks during
/// that fade are ignored. Shift restores the ring immediately. `closeFinished`
/// (the animation completion, or the fallback timer) is the only way `.closing`
/// becomes `.hidden`, and a second one is a no-op.
public struct RingDismissMachine: Equatable, Sendable {
    public private(set) var presence: RingPresence

    public init(presence: RingPresence = .hidden) {
        self.presence = presence
    }

    public mutating func noteShown(_ presence: RingPresence) {
        self.presence = presence
    }

    public mutating func noteHidden() {
        presence = .hidden
    }

    public mutating func handle(_ event: RingDismissEvent) -> RingDismissDecision {
        switch presence {
        case .hidden:
            return .ignore
        case .click:
            return handleClick(event)
        case .drag(let buttonDown):
            return handleDrag(event, buttonDown: buttonDown)
        case .closing:
            return handleClosing(event)
        }
    }

    private mutating func handleClick(_ event: RingDismissEvent) -> RingDismissDecision {
        switch event {
        case .escape:
            return beginClose("escape", resume: .click)
        case .mouseDown(let button, let onWedge):
            switch button {
            case .left:
                guard !onWedge else { return .ignore }
                return beginClose("click-outside", resume: .click)
            case .right:
                return beginClose("right-click", resume: .click)
            case .other:
                return beginClose("mouse-down", resume: .click)
            }
        case .mouseUp(let button, let onWedge):
            switch button {
            case .left:
                guard !onWedge else { return .ignore }
                return beginClose("mouse-up", resume: .click)
            case .right:
                return beginClose("right-mouse-up", resume: .click)
            case .other:
                return beginClose("mouse-up", resume: .click)
            }
        case .buttonsReleased:
            return .ignore
        case .shift(let canCycle):
            guard canCycle else { return beginClose("shift-stuck", resume: .click) }
            return .cycle
        case .appDeactivated:
            return beginClose("deactivate", resume: .click)
        case .spaceChanged:
            return beginClose("space-change", resume: .click)
        case .openWhileVisible:
            return replace("second-open")
        case .dropAccepted:
            return immediate("drop")
        case .dropGraceExpired, .closeFinished:
            return .ignore
        }
    }

    private mutating func handleDrag(_ event: RingDismissEvent, buttonDown: Bool) -> RingDismissDecision {
        let resume = RingResume.drag(buttonDown: buttonDown)
        switch event {
        case .escape:
            return beginClose("escape", resume: resume)
        case .mouseDown(let button, _):
            switch button {
            case .right:
                return beginClose("right-click", resume: resume)
            case .left, .other:
                return beginClose("mouse-down", resume: resume)
            }
        case .mouseUp(let button, let onWedge):
            guard buttonDown else { return .ignore }
            switch button {
            case .left where onWedge:
                return grace("mouse-up-on-wedge")
            case .left:
                return beginClose("drag-ended-outside", resume: resume)
            case .right:
                return beginClose("right-mouse-up", resume: resume)
            case .other:
                return beginClose("mouse-up", resume: resume)
            }
        case .buttonsReleased(let inside):
            guard buttonDown else { return .ignore }
            if inside {
                return grace("buttons-released")
            }
            return beginClose("drag-ended-outside", resume: resume)
        case .shift(let canCycle):
            guard canCycle else { return beginClose("shift-stuck", resume: resume) }
            return .cycle
        case .appDeactivated:
            return beginClose("deactivate", resume: resume)
        case .spaceChanged:
            return beginClose("space-change", resume: resume)
        case .openWhileVisible:
            return replace("second-open")
        case .dropAccepted:
            return immediate("drop")
        case .dropGraceExpired:
            return beginClose("drop-grace", resume: .drag(buttonDown: false))
        case .closeFinished:
            return .ignore
        }
    }

    private mutating func handleClosing(_ event: RingDismissEvent) -> RingDismissDecision {
        switch event {
        case .shift:
            return reopen()
        case .openWhileVisible:
            return reopen()
        case .closeFinished:
            presence = .hidden
            return .finishClose
        case .dropAccepted:
            return immediate("drop")
        case .mouseDown, .mouseUp, .buttonsReleased, .escape, .appDeactivated, .spaceChanged, .dropGraceExpired:
            return .ignore
        }
    }

    private mutating func beginClose(_ reason: String, resume: RingResume) -> RingDismissDecision {
        presence = .closing(resume: resume)
        return .beginClose(reason: reason)
    }

    private mutating func immediate(_ reason: String) -> RingDismissDecision {
        presence = .hidden
        return .dismiss(reason: reason)
    }

    private mutating func replace(_ reason: String) -> RingDismissDecision {
        presence = .hidden
        return .replace(reason: reason)
    }

    private mutating func grace(_ reason: String) -> RingDismissDecision {
        presence = .drag(buttonDown: false)
        return .dismissAfterDropGrace(reason: reason)
    }

    private mutating func reopen() -> RingDismissDecision {
        guard case .closing(let resume) = presence else { return .ignore }
        switch resume {
        case .click:
            presence = .click
        case .drag(let buttonDown):
            presence = .drag(buttonDown: buttonDown)
        }
        return .reopen
    }
}

public enum RingDismissLog {
    public static func line(reason: String) -> String {
        "Pith: dismiss reason=\(reason)"
    }

    public static func closeCancelledByReopen() -> String {
        "Pith: close cancelled by reopen"
    }
}

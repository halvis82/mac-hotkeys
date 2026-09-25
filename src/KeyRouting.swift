import CoreGraphics

let dndKeyCode: Int64 = 178   // F6, the moon key, when Fn is not held
let graveKeyCode: Int64 = 50  // `
let tabKeyCode: Int64 = 48
let escKeyCode: Int64 = 53
let leftArrowKeyCode: Int64 = 123
let rightArrowKeyCode: Int64 = 124
/// Virtual key codes for 1...9, in order, on both the number row and the keypad.
let digitKeyCodes: [Int64] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
let keypadDigitKeyCodes: [Int64] = [83, 84, 85, 86, 87, 88, 89, 91, 92]

/// What the event tap should do with one keyboard event.
///
/// Kept apart from the tap itself so every routing rule can be tested without a real tap. The
/// tap turns each case into a hop onto the main queue, and swallows the event for every case
/// except `pass` and `commit`.
enum KeyAction: Equatable {
    /// Not ours: hand the event on untouched.
    case pass
    case focusKeyDown
    case focusKeyUp
    /// Command was let go with the switcher up. The event itself still passes through.
    case commit
    /// Cmd+Tab. Whether that opens the switcher or advances it is decided when the hop runs,
    /// so it goes by the state at that moment rather than when the key was read.
    case tab(backwards: Bool)
    case cycle
    case cancel
    case moveWithinDesktop(Int)
    case select(position: Int)

    /// Whether the event is kept from reaching anything else.
    var swallows: Bool {
        switch self {
        case .pass, .commit: return false
        default: return true
        }
    }
}

func routeKey(type: CGEventType, code: Int64, flags: CGEventFlags, switcherOpen: Bool) -> KeyAction {
    // --- Focus toggle: the F6 moon key, tap versus hold ---
    if code == dndKeyCode, type == .keyDown || type == .keyUp {
        return type == .keyDown ? .focusKeyDown : .focusKeyUp
    }

    // --- Switcher: Command being released is what commits ---
    if type == .flagsChanged {
        return switcherOpen && !flags.contains(.maskCommand) ? .commit : .pass
    }

    guard type == .keyDown else { return .pass }

    // --- Switcher: Cmd+Tab ---
    if code == tabKeyCode, flags.contains(.maskCommand) {
        return .tab(backwards: flags.contains(.maskShift))
    }

    // --- Fullscreen cycle: Cmd+` ---
    if code == graveKeyCode,
       flags.contains(.maskCommand),
       !flags.contains(.maskControl),
       !flags.contains(.maskAlternate) {
        return .cycle
    }

    // --- Keys that only mean something while the switcher is open ---
    guard switcherOpen else { return .pass }
    switch code {
    case escKeyCode:
        return .cancel
    case leftArrowKeyCode:
        return .moveWithinDesktop(-1)
    case rightArrowKeyCode:
        return .moveWithinDesktop(1)
    default:
        if let position = digitKeyCodes.firstIndex(of: code) ?? keypadDigitKeyCodes.firstIndex(of: code) {
            return .select(position: position)
        }
        return .pass
    }
}

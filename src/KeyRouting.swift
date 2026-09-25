import CoreGraphics
import Foundation

let dndKeyCode: Int64 = 178   // the moon key, which is F6 when Fn is held
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

func routeKey(type: CGEventType, code: Int64, flags: CGEventFlags, switcherOpen: Bool,
              focusKeyEnabled: Bool = true) -> KeyAction {
    // --- Focus toggle: the moon key, tap versus hold ---
    // Left to macOS when the shortcuts it runs are not set up, see FocusShortcuts.
    if code == dndKeyCode, type == .keyDown || type == .keyUp {
        guard focusKeyEnabled else { return .pass }
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

/// Whether keys should go to the switcher, readable from the event tap's own thread.
///
/// Raised the instant Cmd+Tab is seen, before the switcher has actually opened on the main
/// thread, and lowered the instant Command is let go. The keys in between (Escape, arrows, digits
/// and the release itself) are then routed to the switcher in the order they were pressed,
/// however busy the main thread is. Going by the controller's own `isOpen` instead left a gap: a
/// quick tap whose release arrived before the open had run was let through uncounted, and the
/// switcher then opened with nothing left to close it.
///
/// Only the tap raises it. Each raise starts a numbered session, and the main thread may lower
/// it only for the session it is handling: its word arrives late, and a plain "lower" from an
/// earlier session could otherwise land after the tap had raised it for the next Cmd+Tab, lose
/// that session's release, and leave the switcher stuck open.
enum SwitcherGate {
    private static let lock = NSLock()
    private static var active = false
    private static var session: UInt64 = 0

    static var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    /// From the tap: raises the gate, starting a new session unless one is under way. Returns it.
    @discardableResult
    static func raise() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        if !active {
            active = true
            session &+= 1
        }
        return session
    }

    /// From the tap: Command is up, or Escape was pressed.
    static func lower() {
        lock.lock()
        active = false
        lock.unlock()
    }

    /// From the main thread: lowers it only if `session` is still the one under way.
    static func lower(ifSession expected: UInt64) {
        lock.lock()
        if session == expected { active = false }
        lock.unlock()
    }
}

/// Monotonic time in mach ticks, and conversions, for timing the keystroke path.
enum Clock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static var now: UInt64 { mach_absolute_time() }

    /// Milliseconds between two tick readings, zero if they are out of order.
    static func milliseconds(from start: UInt64, to end: UInt64 = mach_absolute_time()) -> Double {
        guard end > start else { return 0 }
        return Double(end - start) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
    }

    /// A keyboard event's timestamp as mach ticks, or nil if it can't be made sense of.
    ///
    /// Documented as nanoseconds, delivered in practice as mach ticks on some systems, so it is
    /// matched against both clocks and kept only if it lands within the last minute of one.
    static func ticks(ofEventTimestamp timestamp: UInt64, now: UInt64 = mach_absolute_time()) -> UInt64? {
        guard timestamp > 0 else { return nil }
        let minuteInTicks = UInt64(60_000_000_000.0 * Double(timebase.denom) / Double(timebase.numer))
        if timestamp <= now, now - timestamp < minuteInTicks { return timestamp }
        let nowNanoseconds = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if timestamp <= nowNanoseconds, nowNanoseconds - timestamp < 60_000_000_000 {
            let ageTicks = UInt64(Double(nowNanoseconds - timestamp) * Double(timebase.denom) / Double(timebase.numer))
            return now > ageTicks ? now - ageTicks : nil
        }
        return nil
    }
}

import Cocoa

// One agent for all three hotkeys.
//
// These used to be three separate apps, which meant three LaunchAgents, three sets of
// Accessibility/Input Monitoring/Screen Recording grants, and three permission dialogs every
// time anything was rebuilt. They share most of their machinery anyway, so they are now a
// single process with a single event tap: grant it once and everything works.

private let logClock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

func log(_ message: String) {
    let line = "\(logClock.string(from: Date())) mac-hotkeys: \(message)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
}

let dndKeyCode: Int64 = 178   // F6, the moon key, when Fn is not held
let graveKeyCode: Int64 = 50  // `
let tabKeyCode: Int64 = 48
let escKeyCode: Int64 = 53
let leftArrowKeyCode: Int64 = 123
let rightArrowKeyCode: Int64 = 124
/// Virtual key codes for 1...9, in order, on both the number row and the keypad.
let digitKeyCodes: [Int64] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
let keypadDigitKeyCodes: [Int64] = [83, 84, 85, 86, 87, 88, 89, 91, 92]

guard let sky = SkyLight() else {
    log("could not resolve SkyLight symbols - macOS may have changed them")
    exit(1)
}

// MARK: - Diagnostics that need no key binding

if CommandLine.arguments.contains("--dump") {
    let tiles = WindowLister.buildTiles(sky)
    let active = sky.activeSpace
    print("active space: \(active)")
    print("tiles (\(tiles.count)), left to right:\n")
    for (index, tile) in tiles.enumerated() {
        let marker = tile.space.id == active ? " <- current" : ""
        switch tile {
        case .window(let space, let window):
            print("  \(index + 1). [fullscreen] space=\(space.id) \(window.appName)\(marker)")
            print("        \"\(window.title)\"")
        case .desktop(let space, let windows):
            print("  \(index + 1). [desktop]    space=\(space.id) \(windows.count) app(s)\(marker)")
            for window in windows {
                print("        \(window.appName)\(window.isMinimized ? " (minimized)" : "") - \"\(window.title)\"")
            }
        }
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

enum Runtime {
    static var sky: SkyLight!
    static var switcher: SwitcherController!
    static var dryRun = false
    static var tap: CFMachPort?
}
Runtime.sky = sky
Runtime.switcher = SwitcherController(sky: sky)

if let index = CommandLine.arguments.firstIndex(of: "--show") {
    let seconds = index + 1 < CommandLine.arguments.count
        ? (Double(CommandLine.arguments[index + 1]) ?? 3.0) : 3.0
    Runtime.switcher.open(backwards: false)
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
    app.run()
}

// MARK: - The one event tap

let mask: CGEventMask =
    (1 << CGEventType.keyDown.rawValue) |
    (1 << CGEventType.keyUp.rawValue) |
    (1 << CGEventType.flagsChanged.rawValue)

func makeEventTap() -> CFMachPort? {
    CGEvent.tapCreate(
        tap: .cghidEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: { proxy, type, event, _ in
            // macOS switches a tap off if a callback is ever slow, and a disabled tap goes
            // silent permanently: every hotkey stops working with no error anywhere. Turning
            // it back on is the only recovery.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = Runtime.tap {
                    log("event tap was disabled by the system, re-enabling")
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return nil
            }

            let switcher = Runtime.switcher!
            let code = event.getIntegerValueField(.keyboardEventKeycode)

            // --- Focus toggle: the F6 moon key, tap versus hold ---
            if code == dndKeyCode, type == .keyDown || type == .keyUp {
                if type == .keyDown {
                    DispatchQueue.main.async { handleKeyDown() }
                } else {
                    DispatchQueue.main.async { handleKeyUp() }
                }
                return nil // swallow, so the system's own DND toggle never sees it
            }

            // --- Switcher: Command being released is what commits ---
            if type == .flagsChanged {
                if switcher.isOpen && !event.flags.contains(.maskCommand) {
                    DispatchQueue.main.async { switcher.commit() }
                }
                return Unmanaged.passUnretained(event)
            }

            guard type == .keyDown else { return Unmanaged.passUnretained(event) }

            // --- Switcher: Cmd+Tab ---
            if code == tabKeyCode, event.flags.contains(.maskCommand) {
                let backwards = event.flags.contains(.maskShift)
                DispatchQueue.main.async {
                    if switcher.isOpen {
                        switcher.advance(by: backwards ? -1 : 1)
                    } else {
                        switcher.open(backwards: backwards)
                    }
                }
                return nil
            }

            // --- Fullscreen cycle: Cmd+` ---
            if code == graveKeyCode,
               event.flags.contains(.maskCommand),
               !event.flags.contains(.maskControl),
               !event.flags.contains(.maskAlternate) {
                DispatchQueue.main.async { cycleWindow(Runtime.sky, dryRun: Runtime.dryRun) }
                return nil
            }

            // --- Keys that only mean something while the switcher is open ---
            guard switcher.isOpen else { return Unmanaged.passUnretained(event) }
            switch code {
            case escKeyCode:
                DispatchQueue.main.async { switcher.cancel() }
                return nil
            case leftArrowKeyCode:
                DispatchQueue.main.async { switcher.moveWithinDesktop(by: -1) }
                return nil
            case rightArrowKeyCode:
                DispatchQueue.main.async { switcher.moveWithinDesktop(by: 1) }
                return nil
            case _ where digitKeyCodes.contains(code) || keypadDigitKeyCodes.contains(code):
                let position = digitKeyCodes.firstIndex(of: code)
                    ?? keypadDigitKeyCodes.firstIndex(of: code)!
                DispatchQueue.main.async { switcher.select(position: position) }
                return nil
            default:
                return Unmanaged.passUnretained(event)
            }
        },
        userInfo: nil
    )
}

/// Waits for permissions rather than exiting without them.
///
/// Exiting is what caused the permission-dialog spam: launchd keeps this agent alive, so every
/// exit meant a relaunch seconds later and every relaunch asked again. Staying up and
/// re-checking quietly means the dialog appears once per launch at most.
var askedForAccessibility = false
var reportedTapFailure = false

func startWhenPermitted() {
    guard AXIsProcessTrusted() else {
        if !askedForAccessibility {
            askedForAccessibility = true
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            log("waiting for Accessibility permission (System Settings > Privacy & Security)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { startWhenPermitted() }
        return
    }

    guard let tap = makeEventTap() else {
        if !reportedTapFailure {
            reportedTapFailure = true
            log("waiting for Input Monitoring permission (System Settings > Privacy & Security)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { startWhenPermitted() }
        return
    }

    Runtime.tap = tap
    CFRunLoopAddSource(CFRunLoopGetCurrent(),
                       CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0),
                       .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    log("running (pid \(ProcessInfo.processInfo.processIdentifier)) - F6 focus, Cmd+` cycle, Cmd+Tab switcher")
}

startWhenPermitted()
app.run()

import Cocoa

// One agent for all three hotkeys.
//
// These used to be three separate apps, which meant three LaunchAgents, three sets of
// Accessibility/Input Monitoring/Screen Recording grants, and three permission dialogs every
// time anything was rebuilt. They share most of their machinery anyway, so they are now a
// single process with a single event tap: grant it once and everything works.

trimLogIfLarge()

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

// Not a background process as far as the scheduler is concerned. Idle agents get App Nap:
// their timers are coalesced and their wakeups deferred, so the first Cmd+Tab after a quiet
// spell waited on the process waking up. Held for the life of the process. Idle sleep is still
// allowed; this only asks for prompt handling while awake.
let latencyActivity = ProcessInfo.processInfo.beginActivity(
    options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
    reason: "Hotkeys must respond the moment they are pressed")

enum Runtime {
    static var sky: SkyLight!
    static var switcher: SwitcherController!
    static var dryRun = false
    static var tap: CFMachPort?
    static var tapThread: Thread?
    /// Whether the moon key press under way belongs to the agent. Only touched on the tap's thread.
    static var focusKeyClaimed = true
}
Runtime.sky = sky
Runtime.switcher = SwitcherController(sky: sky)

if let index = CommandLine.arguments.firstIndex(of: "--show") {
    let seconds = index + 1 < CommandLine.arguments.count
        ? (Double(CommandLine.arguments[index + 1]) ?? 3.0) : 3.0
    Runtime.switcher.open(backwards: false, session: SwitcherGate.raise(),
                          timing: OpenTiming(pressedAt: nil, tappedAt: Clock.now))
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
    app.run()
}

// MARK: - The one event tap

extension CGEvent {
    var isAutorepeat: Bool { getIntegerValueField(.keyboardEventAutorepeat) != 0 }
}

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
            let tappedAt = Clock.now
            // Command going down may be the start of a Cmd+Tab: wake the apps now, so their
            // answers are in by the time Tab is. This does cost something: every Command press,
            // Cmd+C included, lists the windows and asks each app a question, at most once per
            // 300ms. It is a few milliseconds of work, and it is what keeps the first Cmd+Tab
            // after a quiet spell from waiting on apps to wake up. Any other key pressed with
            // Command down may change the windows (Cmd+N, Cmd+W), so earlier answers stop
            // counting as fresh.
            if !SwitcherGate.isActive {
                if type == .flagsChanged, event.flags.contains(.maskCommand) {
                    WindowLister.warm(Runtime.sky)
                } else if type == .keyDown, event.flags.contains(.maskCommand),
                          event.getIntegerValueField(.keyboardEventKeycode) != tabKeyCode {
                    WindowLister.invalidateAnswers()
                }
            }
            // A key typed without Command while the switcher thinks it is up means the release
            // of Command was missed somehow. Close it, and let the key through as typed.
            if type == .keyDown, SwitcherGate.isActive, !event.flags.contains(.maskCommand) {
                SwitcherGate.lower()
                DispatchQueue.main.async { switcher.cancel() }
            }
            // Whether the moon key is ours is decided when it goes down and kept for when it comes up, so
            // macOS never sees half a keypress.
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == dndKeyCode, type == .keyDown, !event.isAutorepeat {
                Runtime.focusKeyClaimed = FocusShortcuts.areInstalled
                FocusShortcuts.check() // in the background, for the next press
            }
            let action = routeKey(type: type,
                                  code: code,
                                  flags: event.flags,
                                  switcherOpen: SwitcherGate.isActive,
                                  focusKeyEnabled: Runtime.focusKeyClaimed)
            switch action {
            case .pass:
                break
            case .focusKeyDown:
                DispatchQueue.main.async { handleKeyDown() }
            case .focusKeyUp:
                DispatchQueue.main.async { handleKeyUp() }
            case .commit:
                SwitcherGate.lower()
                DispatchQueue.main.async { switcher.commit() }
            case .tab(let backwards):
                let session = SwitcherGate.raise()
                let pressedAt = Clock.ticks(ofEventTimestamp: event.timestamp, now: tappedAt)
                DispatchQueue.main.async {
                    if switcher.isOpen {
                        switcher.advance(by: backwards ? -1 : 1)
                    } else {
                        switcher.open(backwards: backwards, session: session,
                                      timing: OpenTiming(pressedAt: pressedAt, tappedAt: tappedAt))
                    }
                }
            case .cycle:
                DispatchQueue.main.async { cycleWindow(Runtime.sky, dryRun: Runtime.dryRun) }
            case .cancel:
                SwitcherGate.lower()
                DispatchQueue.main.async { switcher.cancel() }
            case .moveWithinDesktop(let step):
                DispatchQueue.main.async { switcher.moveWithinDesktop(by: step) }
            case .select(let position):
                DispatchQueue.main.async { switcher.select(position: position) }
            }
            // Swallowed keys never reach the system, so the moon key's own DND toggle and the
            // Dock's Cmd+Tab both stay out of it.
            return action.swallows ? nil : Unmanaged.passUnretained(event)
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
    // The tap runs on a thread of its own. It sits in front of every keystroke on the system and
    // macOS waits for its answer, so on the main thread anything that held the main thread,
    // drawing the switcher or waiting on a slow app, delayed typing everywhere and left Cmd+Tab
    // queued behind it. The callback only reads the gate and hops to the main queue.
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    let tapThread = Thread {
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopRun()
    }
    tapThread.name = "event tap"
    tapThread.qualityOfService = .userInteractive
    tapThread.start()
    Runtime.tapThread = tapThread
    log("running (pid \(ProcessInfo.processInfo.processIdentifier)) - moon key focus, Cmd+` cycle, Cmd+Tab switcher")
    Runtime.switcher.prewarm()
    FocusShortcuts.check()
}

startWhenPermitted()
app.run()

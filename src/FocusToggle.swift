import Cocoa

// Replaces the F6 "moon" key's built-in behavior with:
//   tap   -> if any Focus is active, turn it off. Otherwise turn on Do Not Disturb.
//   hold  -> if any Focus is active, turn it off. Otherwise turn on the "Nothing" Focus.
//
// The key normally toggles Do Not Disturb itself before any app ever sees it, so we
// intercept it with a CGEventTap at the HID level and swallow it (return nil), then
// drive the actual Focus state changes through Shortcuts (the only public, stable
// surface Apple exposes for this - see README for the three shortcuts this expects).

private let holdThreshold: TimeInterval = 0.35

private let shortcutFocusOn = "dnd on"
private let shortcutNothingOn = "nothing on"
private let shortcutFocusOff = "dnd/nothing off"

private let assertionsPath =
    NSHomeDirectory() + "/Library/DoNotDisturb/DB/Assertions.json"


/// What we last set the Focus to ourselves, used when the authoritative file cannot be read.
private var lastKnownFocusActive = false
private var reportedUnreadableAssertions = false

/// Whether any Focus is currently on, read from the file donotdisturbd maintains.
/// Returns nil when that file cannot be read, which is a different thing from "no Focus".
private func readFocusState() -> Bool? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: assertionsPath)) else { return nil }
    return parseFocusAssertions(data)
}

/// Whether the contents of Assertions.json say a Focus is on. Nil when they can't be read as
/// the expected shape, which must never be mistaken for "off".
func parseFocusAssertions(_ data: Data) -> Bool? {
    guard let object = try? JSONSerialization.jsonObject(with: data),
          let json = object as? [String: Any],
          let entries = json["data"] as? [[String: Any]],
          let first = entries.first,
          let records = first["storeAssertionRecords"] as? [[String: Any]]
    else { return nil }
    return !records.isEmpty
}

/// True if any Focus mode is currently active.
///
/// The file is authoritative but sits behind Full Disk Access. Without that grant the read
/// fails, and treating the failure as "nothing is active" is what made the moon key turn Do Not
/// Disturb *on* every time instead of toggling it off. So when the file is unreadable we fall
/// back to what we last set ourselves, which toggles correctly as long as Focus isn't also being
/// changed from Control Center. Granting Full Disk Access makes it exact again.
private func isAnyFocusActive() -> Bool {
    if let state = readFocusState() {
        lastKnownFocusActive = state
        return state
    }
    if !reportedUnreadableAssertions {
        reportedUnreadableAssertions = true
        log("cannot read Focus state (needs Full Disk Access); tracking it locally instead")
    }
    return lastKnownFocusActive
}

private let actionQueue = DispatchQueue(label: "focustoggle.action")

/// Runs one of the Focus shortcuts, and refuses to wait forever for it.
///
/// `shortcuts run` hangs outright sometimes: the process sits there indefinitely with the
/// shortcut never firing. Because these run on one serial queue, a single hang used to block
/// every later press of the key, so the moon key simply stopped responding until the agent was
/// restarted. Anything still running after a few seconds is killed so the queue keeps moving.
private func runShortcut(_ name: String, marking active: Bool) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
    task.arguments = ["run", name]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
    } catch {
        log("failed to launch shortcuts run \"\(name)\": \(error)")
        return
    }

    let watchdog = DispatchWorkItem {
        if task.isRunning {
            log("shortcut \"\(name)\" hung; killing it")
            task.terminate()
        }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: watchdog)
    task.waitUntilExit()
    watchdog.cancel()

    if task.terminationStatus == 0 {
        lastKnownFocusActive = active
        log("ran shortcut \"\(name)\"")
    } else {
        log("shortcut \"\(name)\" exited \(task.terminationStatus)")
    }
}

private func onTap() {
    let active = isAnyFocusActive()
    let name = active ? shortcutFocusOff : shortcutFocusOn
    actionQueue.async { runShortcut(name, marking: !active) }
}

private func onHold() {
    let active = isAnyFocusActive()
    let name = active ? shortcutFocusOff : shortcutNothingOn
    actionQueue.async { runShortcut(name, marking: !active) }
}

// MARK: - Key handling

/// Tells a tap from a hold: a hold fires as soon as the threshold passes with the key still down,
/// a tap fires on release if the hold never did. Key repeat is ignored.
final class TapHoldDetector {
    private let threshold: TimeInterval
    private let onTap: () -> Void
    private let onHold: () -> Void

    private var keyIsDown = false
    private var holdFired = false
    private var holdWorkItem: DispatchWorkItem?

    init(threshold: TimeInterval, onTap: @escaping () -> Void, onHold: @escaping () -> Void) {
        self.threshold = threshold
        self.onTap = onTap
        self.onHold = onHold
    }

    func keyDown() {
        if keyIsDown { return } // ignore any stray repeat
        keyIsDown = true
        holdFired = false
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.holdFired = true
            self.onHold()
        }
        holdWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + threshold, execute: item)
    }

    func keyUp() {
        guard keyIsDown else { return }
        keyIsDown = false
        holdWorkItem?.cancel()
        holdWorkItem = nil
        if !holdFired {
            onTap()
        }
    }
}

private let moonKey = TapHoldDetector(threshold: holdThreshold, onTap: onTap, onHold: onHold)

func handleKeyDown() { moonKey.keyDown() }

func handleKeyUp() { moonKey.keyUp() }

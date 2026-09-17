import Cocoa
import ApplicationServices

// Replaces the F6 "moon" key's built-in behavior with:
//   tap   -> if any Focus is active, turn it off. Otherwise turn on Do Not Disturb.
//   hold  -> if any Focus is active, turn it off. Otherwise turn on the "Nothing" Focus.
//
// The key normally toggles Do Not Disturb itself before any app ever sees it, so we
// intercept it with a CGEventTap at the HID level and swallow it (return nil), then
// drive the actual Focus state changes through Shortcuts (the only public, stable
// surface Apple exposes for this - see README for the three shortcuts this expects).

private let dndKeyCode: Int64 = 178          // F6 without Fn, confirmed by sniffing
private let holdThreshold: TimeInterval = 0.35

private let shortcutFocusOn = "dnd on"
private let shortcutNothingOn = "nothing on"
private let shortcutFocusOff = "dnd/nothing off"

private let assertionsPath =
    NSHomeDirectory() + "/Library/DoNotDisturb/DB/Assertions.json"

private func log(_ message: String) {
    FileHandle.standardError.write("focus-toggle: \(message)\n".data(using: .utf8)!)
}

/// True if any Focus mode is currently active, read straight from the DB file
/// donotdisturbd maintains. This is undocumented but immediate (no process
/// spawn), and was verified empirically to reflect state changes within
/// milliseconds. If Apple changes this file's layout in a future macOS this
/// will need updating - it fails safe (treats unreadable/unexpected data as "no focus active").
private func isAnyFocusActive() -> Bool {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: assertionsPath))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["data"] as? [[String: Any]],
              let first = entries.first,
              let records = first["storeAssertionRecords"] as? [[String: Any]]
        else {
            log("assertions file parsed but had unexpected shape")
            return false
        }
        return !records.isEmpty
    } catch {
        log("cannot read assertions file: \(error)")
        return false
    }
}

private let actionQueue = DispatchQueue(label: "focustoggle.action")

private func runShortcut(_ name: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
    task.arguments = ["run", name]
    task.standardOutput = FileHandle.nullDevice
    let errPipe = Pipe()
    task.standardError = errPipe
    do {
        try task.run()
    } catch {
        log("failed to launch shortcuts run \"\(name)\": \(error)")
        return
    }
    task.waitUntilExit()
    if task.terminationStatus != 0 {
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: errData, encoding: .utf8) ?? ""
        log("shortcut \"\(name)\" exited \(task.terminationStatus): \(errText)")
    } else {
        log("ran shortcut \"\(name)\"")
    }
}

private func onTap() {
    let name = isAnyFocusActive() ? shortcutFocusOff : shortcutFocusOn
    actionQueue.async { runShortcut(name) }
}

private func onHold() {
    let name = isAnyFocusActive() ? shortcutFocusOff : shortcutNothingOn
    actionQueue.async { runShortcut(name) }
}

// MARK: - Key handling

private var keyIsDown = false
private var holdFired = false
private var holdWorkItem: DispatchWorkItem?

private func handleKeyDown() {
    if keyIsDown { return } // ignore any stray repeat
    keyIsDown = true
    holdFired = false
    let item = DispatchWorkItem {
        holdFired = true
        onHold()
    }
    holdWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: item)
}

private func handleKeyUp() {
    guard keyIsDown else { return }
    keyIsDown = false
    holdWorkItem?.cancel()
    holdWorkItem = nil
    if !holdFired {
        onTap()
    }
}

// MARK: - Event tap

let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

func makeEventTap() -> CFMachPort? {
    CGEvent.tapCreate(
        tap: .cghidEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: { proxy, type, event, refcon in
            guard event.getIntegerValueField(.keyboardEventKeycode) == dndKeyCode else {
                return Unmanaged.passUnretained(event)
            }
            if type == .keyDown {
                DispatchQueue.main.async { handleKeyDown() }
            } else if type == .keyUp {
                DispatchQueue.main.async { handleKeyUp() }
            }
            return nil // swallow: never let the system's own DND toggle see it
        },
        userInfo: nil
    )
}

/// Waits for permissions rather than exiting without them.
///
/// Exiting caused permission-dialog spam: launchd keeps this agent alive, so every exit meant a
/// relaunch a few seconds later and every relaunch asked again. Staying up and re-checking
/// quietly means the dialog appears once, and granting it takes effect without a manual restart.
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

    CFRunLoopAddSource(CFRunLoopGetCurrent(),
                       CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0),
                       .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    log("running (pid \(ProcessInfo.processInfo.processIdentifier))")
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
startWhenPermitted()
app.run()

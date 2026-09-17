import Cocoa
import ApplicationServices

// Test: can we swallow keyCode 178 (the F6 moon/DND key) before macOS's own
// Focus toggle handles it? If interception works, tapping F6 while this runs
// should print DOWN/UP but NOT actually toggle Do Not Disturb in Control Center.
// Also measures hold duration and whether the key auto-repeats while held.

let dndKeyCode: Int64 = 178

if !AXIsProcessTrusted() {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
    print("Requesting Accessibility permission - approve it in System Settings, then re-run.")
}

var downAt: Date?
var repeatCount = 0

let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

guard let tap = CGEvent.tapCreate(
    tap: .cghidEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: mask,
    callback: { proxy, type, event, refcon in
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard code == dndKeyCode else { return Unmanaged.passUnretained(event) }

        if type == .keyDown {
            if downAt == nil {
                downAt = Date()
                repeatCount = 0
                print("DOWN")
            } else {
                repeatCount += 1
                print("DOWN (repeat \(repeatCount))")
            }
        } else if type == .keyUp {
            let held = downAt.map { Date().timeIntervalSince($0) } ?? -1
            print("UP after \(String(format: "%.3f", held))s, \(repeatCount) repeat(s)")
            downAt = nil
        }
        fflush(stdout)
        return nil // swallow: system should never see this key
    },
    userInfo: nil
) else {
    print("Failed to create event tap - grant Input Monitoring + Accessibility to this binary, then re-run.")
    exit(1)
}

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
print("Listening for F6 (moon/DND key). Tap it once, then hold it ~2s. Ctrl+C to stop.")
fflush(stdout)
CFRunLoopRun()

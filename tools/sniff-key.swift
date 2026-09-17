import Cocoa

// Diagnostic tool: logs every low-level keyboard / system-defined event so we
// can see exactly what a given hardware key (e.g. the F6 "Do Not Disturb"
// moon key) actually sends. Needs Input Monitoring permission the first time
// it runs - macOS will prompt, or silently deliver nothing until you grant it
// in System Settings > Privacy & Security > Input Monitoring, then re-run.

func log(_ s: String) {
    print(s)
    fflush(stdout)
}

let mask: CGEventMask =
    (1 << CGEventType.keyDown.rawValue) |
    (1 << CGEventType.keyUp.rawValue) |
    (1 << CGEventType.flagsChanged.rawValue) |
    (UInt64(1) << 14) // NX_SYSDEFINED = 14 (kCGEventTapDisabledByTimeout etc excluded)

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .listenOnly,
    eventsOfInterest: mask,
    callback: { proxy, type, event, refcon in
        if type.rawValue == 14 {
            // NSSystemDefined-equivalent CGEvent: decode via NSEvent for data1/data2.
            if let ns = NSEvent(cgEvent: event) {
                let data1 = ns.data1
                let keyCode = (data1 & 0xFFFF0000) >> 16
                let keyState = (data1 & 0xFF00) >> 8
                log("SYSDEFINED subtype=\(ns.subtype.rawValue) keyCode=\(keyCode) keyState=\(keyState == 0xA ? "down" : keyState == 0xB ? "up" : "\(keyState)") data1=\(data1) data2=\(ns.data2)")
            } else {
                log("SYSDEFINED (unparsed)")
            }
        } else if type == .keyDown || type == .keyUp {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            log("\(type == .keyDown ? "KEYDOWN" : "KEYUP  ") keyCode=\(code)")
        } else if type == .flagsChanged {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            log("FLAGS   keyCode=\(code) flags=\(event.flags.rawValue)")
        }
        return Unmanaged.passUnretained(event)
    },
    userInfo: nil
) else {
    log("Failed to create event tap. Grant Input Monitoring permission to this binary in")
    log("System Settings > Privacy & Security > Input Monitoring, then re-run this tool.")
    exit(1)
}

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
log("Listening. Press the key(s) you want identified (Ctrl+C to stop).")
CFRunLoopRun()

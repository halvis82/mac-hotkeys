import Cocoa

// Synthesizes a key down+up for a given virtual keycode via the HID event tap,
// so we can test hotkey handling without a human pressing a physical key.
// Usage: synth-key <keycode> [holdMillis] [cmd] [shift] [alt] [ctrl]

let args = CommandLine.arguments
guard args.count >= 2, let code = CGKeyCode(args[1]) else {
    print("usage: synth-key <keycode> [holdMillis] [cmd] [shift] [alt] [ctrl]")
    exit(1)
}
let holdMillis = args.count >= 3 ? (UInt32(args[2]) ?? 0) : 0

var flags: CGEventFlags = []
if args.contains("cmd") { flags.insert(.maskCommand) }
if args.contains("shift") { flags.insert(.maskShift) }
if args.contains("alt") { flags.insert(.maskAlternate) }
if args.contains("ctrl") { flags.insert(.maskControl) }

let src = CGEventSource(stateID: .hidSystemState)
guard let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true) else {
    print("failed to create down event"); exit(1)
}
if !flags.isEmpty { down.flags = flags }
down.post(tap: .cghidEventTap)
if holdMillis > 0 { usleep(holdMillis * 1000) }
guard let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) else {
    print("failed to create up event"); exit(1)
}
if !flags.isEmpty { up.flags = flags }
up.post(tap: .cghidEventTap)
print("posted keyCode \(code) down/up (hold \(holdMillis)ms, flags \(flags.rawValue))")

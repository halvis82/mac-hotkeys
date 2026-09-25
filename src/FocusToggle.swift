import Cocoa

// The moon key (the Do Not Disturb key, which doubles as F6), driven through three Shortcuts,
// named in MoonKeyShortcuts:
//   tap   -> if any Focus is on, run the "off" shortcut. Otherwise run the "tap" one.
//   hold  -> if the hold shortcut's Focus is on, run the "off" one. Otherwise run the "hold" one,
//            which switches to it from whatever else is on, Do Not Disturb included.
//
// The key normally toggles Do Not Disturb itself before any app sees it, so it is intercepted
// by the event tap and swallowed, and the Focus changes go through Shortcuts, the only public
// way to set a Focus. Which Focus each shortcut sets is up to whoever makes them.

private let holdThreshold: TimeInterval = 0.35

/// Which shortcuts the moon key runs, by name.
///
/// Set in ~/.config/mac-hotkeys/moon-key.json, for example
///     {"tap": "My DND on", "hold": "My Work on", "off": "My Focus off"}
/// Any name left out, or the whole file, falls back to the defaults below. Read again, along with
/// which shortcuts exist, in the background on every press, so an edit applies from the press
/// after it has been noticed, with no restart.
struct MoonKeyShortcuts: Equatable {
    var tap = "Moon Key Tap"
    var hold = "Moon Key Hold"
    var off = "Moon Key Off"

    static let configPath = NSHomeDirectory() + "/.config/mac-hotkeys/moon-key.json"

    /// The names from a config file's contents, or nil if it is not a JSON object.
    static func parse(_ data: Data) -> MoonKeyShortcuts? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var names = MoonKeyShortcuts()
        func name(_ key: String) -> String? {
            guard let value = object[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        names.tap = name("tap") ?? names.tap
        names.hold = name("hold") ?? names.hold
        names.off = name("off") ?? names.off
        return names
    }

    /// The configured names, or the defaults when there is no config file. A file that cannot
    /// be read as JSON also gives the defaults, and is logged.
    static func load() -> MoonKeyShortcuts {
        guard let data = FileManager.default.contents(atPath: configPath) else { return MoonKeyShortcuts() }
        guard let names = parse(data) else {
            log("\(configPath) is not valid JSON, using the default shortcut names")
            return MoonKeyShortcuts()
        }
        return names
    }
}

private let assertionsPath =
    NSHomeDirectory() + "/Library/DoNotDisturb/DB/Assertions.json"


/// What we last set the Focus to ourselves, used when the authoritative file cannot be read.
/// What the Focus assertions file says: off, or on in a mode, named by its identifier.
enum FocusReading: Equatable {
    case off
    case on(mode: String?)
}

/// The Focus as the moon key sees it: off, one of the two modes its shortcuts turn on, or some
/// other mode set from elsewhere.
enum FocusState: Equatable {
    case off
    case tapMode
    case holdMode
    case other
}

enum MoonKeyGesture { case tap, hold }
enum MoonKeyAction: Equatable { case tap, hold, off }

/// Which shortcut a press runs.
///
/// A tap turns off whatever is on, or else turns on its mode. A hold switches to its mode from
/// anything else, Do Not Disturb included, and turns it off only when its mode is already the
/// one on. Holding used to turn off any Focus, so going from Do Not Disturb to the hold mode
/// took two presses.
func moonKeyAction(for gesture: MoonKeyGesture, in state: FocusState) -> MoonKeyAction {
    switch gesture {
    case .tap: return state == .off ? .tap : .off
    case .hold: return state == .holdMode ? .off : .hold
    }
}

/// What the assertions file says, or nil when it can't be read as the expected shape, which
/// must never be mistaken for "off".
func parseFocusReading(_ data: Data) -> FocusReading? {
    guard let object = try? JSONSerialization.jsonObject(with: data),
          let json = object as? [String: Any],
          let entries = json["data"] as? [[String: Any]],
          let first = entries.first,
          let records = first["storeAssertionRecords"] as? [[String: Any]]
    else { return nil }
    guard let record = records.first else { return .off }
    let details = record["assertionDetails"] as? [String: Any]
    return .on(mode: details?["assertionDetailsModeIdentifier"] as? String)
}

/// Whether the contents of Assertions.json say a Focus is on. Nil when they can't be read.
func parseFocusAssertions(_ data: Data) -> Bool? {
    parseFocusReading(data).map { $0 != .off }
}

/// Names the Focus that is on, from the file when it could be read, and otherwise from what the
/// agent last did itself.
///
/// The file only gives a mode identifier, and which identifier each shortcut turns on is learned
/// by reading the file after running it. Until that has happened, a mode that is on is taken to
/// be the one the agent last turned on itself, if it did.
func classifyFocus(_ reading: FocusReading?,
                   tapMode: String?,
                   holdMode: String?,
                   lastKnown: FocusState) -> FocusState {
    guard let reading = reading else { return lastKnown }
    guard case .on(let mode) = reading else { return .off }
    if let mode = mode, mode == holdMode { return .holdMode }
    if let mode = mode, mode == tapMode { return .tapMode }
    if lastKnown == .holdMode, holdMode == nil { return .holdMode }
    if lastKnown == .tapMode, tapMode == nil { return .tapMode }
    return .other
}

/// What the agent last did itself, for when the file can't be read. Main thread only.
private var lastKnownFocus: FocusState = .off
private var reportedUnreadableAssertions = false

private let tapModeKey = "moonKey.tapFocusMode"
private let holdModeKey = "moonKey.holdFocusMode"

/// The Focus assertions file needs Full Disk Access. A failed read is not the same as "off":
/// treating it as off is what once made the key turn Do Not Disturb on every single time.
private func readFocus() -> FocusReading? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: assertionsPath)) else { return nil }
    return parseFocusReading(data)
}

private func currentFocus() -> FocusState {
    let reading = readFocus()
    if reading == nil, !reportedUnreadableAssertions {
        reportedUnreadableAssertions = true
        log("cannot read Focus state (needs Full Disk Access); tracking it locally instead")
    }
    let state = classifyFocus(reading,
                              tapMode: UserDefaults.standard.string(forKey: tapModeKey),
                              holdMode: UserDefaults.standard.string(forKey: holdModeKey),
                              lastKnown: lastKnownFocus)
    lastKnownFocus = state
    return state
}

/// After a shortcut turned a mode on, reads which one it was, so it can be recognized later.
/// The assertion is written a moment after the shortcut returns, so this waits for it.
private func learnMode(for gesture: MoonKeyGesture) {
    for _ in 0..<20 {
        switch readFocus() {
        case nil:
            return // no Full Disk Access: nothing to learn, and no reason to hold up the next press
        case .on(let mode?)?:
            UserDefaults.standard.set(mode, forKey: gesture == .hold ? holdModeKey : tapModeKey)
            return
        default:
            usleep(100_000)
        }
    }
}

/// Whether the three shortcuts exist, so the key can be left to macOS until they do.
///
/// Anyone who has not made them would otherwise lose the moon key entirely: it would be
/// swallowed, run shortcuts that do not exist, and never reach macOS's own Do Not Disturb
/// toggle. Checked in the background at launch and again whenever the key is pressed while they
/// are missing, so it starts working as soon as they are made, with no restart.
enum FocusShortcuts {
    private static let lock = NSLock()
    private static var installed = false
    private static var names = MoonKeyShortcuts()
    private static var reportedNames: MoonKeyShortcuts?

    /// The names in use, as of the last check.
    static var current: MoonKeyShortcuts {
        lock.lock()
        defer { lock.unlock() }
        return names
    }
    private static var checking = false
    private static var reportedMissing = false

    static var areInstalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return installed
    }

    static func check() {
        lock.lock()
        if checking { lock.unlock(); return }
        checking = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            task.arguments = ["list"]
            let output = Pipe()
            task.standardOutput = output
            task.standardError = FileHandle.nullDevice
            var existing: Set<String> = []
            if (try? task.run()) != nil {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                existing = Set((String(data: data, encoding: .utf8) ?? "").split(separator: "\n").map(String.init))
            }
            let configured = MoonKeyShortcuts.load()
            let required = [configured.tap, configured.hold, configured.off]
            let missing = required.filter { !existing.contains($0) }
            lock.lock()
            installed = missing.isEmpty
            names = configured
            let announce = missing.isEmpty && reportedNames != configured
            if announce { reportedNames = configured }
            checking = false
            let report = !missing.isEmpty && !reportedMissing
            if report { reportedMissing = true }
            lock.unlock()
            if announce {
                log("moon key runs \"\(configured.tap)\" on tap, \"\(configured.hold)\" on hold, \"\(configured.off)\" to turn off")
            }
            if report {
                log("moon key left to macOS: Shortcuts \(missing.map { "\"\($0)\"" }.joined(separator: ", ")) not found (see README)")
            }
        }
    }
}

private let actionQueue = DispatchQueue(label: "focustoggle.action")

/// Runs one of the Focus shortcuts, and refuses to wait forever for it.
///
/// `shortcuts run` hangs outright sometimes: the process sits there indefinitely with the
/// shortcut never firing. Because these run on one serial queue, a single hang used to block
/// every later press of the key, so the moon key simply stopped responding until the agent was
/// restarted. Anything still running after a few seconds is killed so the queue keeps moving.
private func runShortcut(_ name: String, for action: MoonKeyAction) {
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
        let state: FocusState = action == .off ? .off : action == .hold ? .holdMode : .tapMode
        DispatchQueue.main.async { lastKnownFocus = state }
        switch action {
        case .tap: learnMode(for: .tap)
        case .hold: learnMode(for: .hold)
        case .off: break
        }
        log("ran shortcut \"\(name)\"")
    } else {
        log("shortcut \"\(name)\" exited \(task.terminationStatus)")
    }
}

private func press(_ gesture: MoonKeyGesture) {
    let action = moonKeyAction(for: gesture, in: currentFocus())
    let shortcuts = FocusShortcuts.current
    let name: String
    switch action {
    case .tap: name = shortcuts.tap
    case .hold: name = shortcuts.hold
    case .off: name = shortcuts.off
    }
    actionQueue.async { runShortcut(name, for: action) }
}

private func onTap() { press(.tap) }

private func onHold() { press(.hold) }

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

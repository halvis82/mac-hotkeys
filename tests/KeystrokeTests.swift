import Cocoa

// Types real keys into the installed agent, so it only runs with `./test.sh --keys`. It flashes
// the switcher and cancels it with Escape, so no window moves, except for one quick tap at the
// end, which switches to the previous window as a real quick tap does. It reads the agent's log for
// what happened. This is the whole keystroke path, tap thread and all, and the timing it reports
// is what a person feels: from the key's own timestamp to the panel being up.

private let logPath = NSHomeDirectory() + "/Library/Logs/com.halvor.machotkeys.log"
private let commandKey: CGKeyCode = 55

private func post(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
    let source = CGEventSource(stateID: .hidSystemState)
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
    event.flags = flags
    event.post(tap: .cghidEventTap)
}

/// Command down, with the flags-changed event a real keyboard sends.
private func commandDown() {
    let source = CGEventSource(stateID: .hidSystemState)
    let event = CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: true)
    event?.type = .flagsChanged
    event?.flags = .maskCommand
    event?.post(tap: .cghidEventTap)
}

private func commandUp() {
    let source = CGEventSource(stateID: .hidSystemState)
    let event = CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: false)
    event?.type = .flagsChanged
    event?.flags = []
    event?.post(tap: .cghidEventTap)
}

private func logLines() -> [String] {
    (try? String(contentsOfFile: logPath, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
}

/// The "open:" lines written since `count` lines were in the log.
private func opens(since count: Int) -> [String] {
    Array(logLines().dropFirst(count)).filter { $0.contains(" open: ") }
}

/// Total milliseconds from an "open:" line, as in "open: 4 tiles, sel 2, 9ms (key ...".
private func totalMilliseconds(_ line: String) -> Double? {
    guard let range = line.range(of: #"(SLOW )?(\d+)ms \("#, options: .regularExpression) else { return nil }
    let digits = line[range].filter(\.isNumber)
    return Double(digits)
}

/// Whether any window of the agent is on screen, which is the switcher panel if anything.
/// Found by process, since the window server reports the owner by its display name.
private func agentPanelOnScreen() -> Bool {
    guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.halvor.machotkeys").first
    else { return false }
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.contains { ($0[kCGWindowOwnerPID as String] as? pid_t) == agent.processIdentifier }
}

func keystrokeTests(_ sky: SkyLight) {
    suite("Real keystrokes into the installed agent (flashes the switcher)") {
        test("the agent is running, and its panel is off screen to start with") {
            expect(!NSRunningApplication.runningApplications(withBundleIdentifier: "com.halvor.machotkeys").isEmpty,
                   "the agent is not running, install it first")
            expect(!agentPanelOnScreen())
        }
        let startSpace = sky.activeSpace

        // Cmd+Tab after a quiet spell, then Escape: the realistic first press of the day.
        var totals: [Double] = []
        for round in 1...8 {
            usleep(3_000_000) // let every app, and the agent, go idle
            let before = logLines().count
            commandDown()
            usleep(120_000)
            post(48, down: true, flags: .maskCommand)
            post(48, down: false, flags: .maskCommand)
            runMainLoop(for: 0.35)
            let shown = agentPanelOnScreen()
            post(53, down: true, flags: .maskCommand)
            post(53, down: false, flags: .maskCommand)
            commandUp()
            runMainLoop(for: 0.25)
            let lines = opens(since: before)
            test("Cmd+Tab after idle opens at once, and Escape closes it, round \(round)") {
                expectEqual(lines.count, 1, "expected one open in the log, got \(lines)")
                expect(shown, "the panel was not on screen 350ms after Tab")
                expect(!agentPanelOnScreen(), "the panel was still up after Escape")
                expectEqual(sky.activeSpace, startSpace, "Escape must not move anything")
                if let line = lines.first, let total = totalMilliseconds(line) {
                    totals.append(total)
                    print("      \(line.components(separatedBy: " open: ").last ?? line)")
                }
            }
        }
        if !totals.isEmpty {
            let sorted = totals.sorted()
            print(String(format: "      key to panel after 3s idle: median %.0fms, worst %.0fms", sorted[sorted.count / 2], sorted.last!))
            test("key to panel stays under a frame or two after idle") {
                expect(sorted[sorted.count / 2] < 25, "median \(sorted[sorted.count / 2])ms")
                expect(sorted.last! < 60, "worst \(sorted.last!)ms")
            }
        }

        // The quick tap: Tab and the release of Command land before the main thread has opened
        // the switcher. The release must still count, so it commits instead of staying open.
        usleep(1_000_000)
        commandDown()
        usleep(60_000)
        post(48, down: true, flags: .maskCommand)
        post(48, down: false, flags: .maskCommand)
        commandUp()
        runMainLoop(for: 1.5)
        test("a very quick Cmd+Tab tap never leaves the switcher stuck open") {
            expect(!agentPanelOnScreen(), "the switcher stayed open after Command was released")
        }
    }
}

import Cocoa

// Cmd+` that also works across fullscreen Spaces.
//
// macOS's built-in "cycle windows of the front app" skips any window that lives in its own
// fullscreen Space, which makes it useless once you fullscreen anything. This replaces it:
// it finds every window of the frontmost app, figures out which Space each one is on, switches
// to that Space if needed, and raises the window.
//
// The window list and the navigation are shared with the Cmd+Tab switcher, so the two cannot
// drift apart in which windows they consider real or how they travel between Spaces.

// MARK: - Where the last press left us

/// The window a verified press moved to, and when.
///
/// Accessibility keeps reporting the old focused window for a few hundred milliseconds after a
/// Space transition has visibly finished. Two presses in quick succession would both read that
/// stale answer, both compute the same target, and the cycle would sit between two windows
/// instead of going round. Recorded only once a move has been verified, so a press that went
/// nowhere leaves the cycle exactly where it was.
private struct CyclePosition {
    let pid: pid_t
    let windowID: CGWindowID
    let at: Date
}
private var lastCycle: CyclePosition?

/// A press is in flight, and whether one arrived while it was.
///
/// Key repeat and impatient presses would otherwise stack navigations on top of each other, each
/// reading a window list the one before it is still changing. Holding one press rather than
/// dropping it means a quick double press still advances twice.
private var cycleInFlight = false
private var cyclePending = false

// MARK: - The action

func cycleWindow(_ sky: SkyLight, dryRun: Bool, target: NSRunningApplication? = nil) {
    guard let app = target ?? NSWorkspace.shared.frontmostApplication else { return }
    let pid = app.processIdentifier

    if cycleInFlight {
        cyclePending = true
        return
    }

    let all = WindowLister.switchableWindows(ofPID: pid, sky)
    guard all.count > 1 else {
        log("\(app.localizedName ?? "?") has \(all.count) cyclable window(s), nothing to switch to")
        return
    }

    var current = WindowActions.focusedWindowID(ofPID: pid)
    if let memory = lastCycle, memory.pid == pid,
       Date().timeIntervalSince(memory.at) < 1.2,
       all.contains(where: { $0.id == memory.windowID }) {
        current = memory.windowID
    }
    let index = all.firstIndex { $0.id == current } ?? 0
    let next = all[(index + 1) % all.count]
    let activeSpace = sky.activeSpace

    let nextSpace = sky.space(ofWindow: next.id)
    let sameSpace = nextSpace == activeSpace ? " (same space)" : ""
    let spaceText = nextSpace.map(String.init) ?? "none"
    log("\(app.localizedName ?? "?"): \(all.count) windows, "
        + "current=\(current.map(String.init) ?? "?") -> wid=\(next.id) "
        + "space=\(spaceText)\(sameSpace) \"\(next.title)\"\(dryRun ? " [DRY RUN]" : "")")
    if dryRun { return }

    // Hand over to the switcher's activation, rather than switching Spaces here. Cycling can
    // land on a window sitting on the desktop just as easily as on a fullscreen one, and
    // leaving a fullscreen Space with the window server directly draws the target on top of the
    // fullscreen app instead of travelling to the desktop. That path knows the difference.
    guard let space = nextSpace, let targetSpace = sky.spaceInfo(id: space) else {
        log("no Space for wid=\(next.id)")
        return
    }

    cycleInFlight = true
    WindowActions.activate(window: next, space: targetSpace, sky) { arrived in
        cycleInFlight = false
        if arrived {
            lastCycle = CyclePosition(pid: pid, windowID: next.id, at: Date())
        } else {
            log("cycle to wid=\(next.id) did not arrive")
        }
        if cyclePending {
            cyclePending = false
            cycleWindow(sky, dryRun: dryRun, target: target)
        }
    }
}


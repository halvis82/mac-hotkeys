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

// MARK: - The action

func cycleWindow(_ sky: SkyLight, dryRun: Bool, target: NSRunningApplication? = nil) {
    guard let app = target ?? NSWorkspace.shared.frontmostApplication else { return }
    let pid = app.processIdentifier
    let all = WindowLister.switchableWindows(ofPID: pid, sky)
    guard all.count > 1 else {
        log("\(app.localizedName ?? "?") has \(all.count) cyclable window(s), nothing to switch to")
        return
    }

    let current = WindowActions.focusedWindowID(ofPID: pid)
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
    WindowActions.activate(window: next, space: targetSpace, sky)
}


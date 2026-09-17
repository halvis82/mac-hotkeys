import Cocoa

// Cmd+` that also works across fullscreen Spaces.
//
// macOS's built-in "cycle windows of the front app" skips any window that lives in its own
// fullscreen Space, which makes it useless once you fullscreen anything. This replaces it:
// it finds every window of the frontmost app, figures out which Space each one is on, switches
// to that Space if needed, and raises the window.
//
// Space switching has no public API, so this uses SkyLight private symbols (resolved at runtime
// via dlsym so a missing symbol degrades to "do nothing" instead of failing to launch).



// MARK: - Window model

private struct AppWindow {
    let id: CGWindowID
    let space: UInt64
    let title: String
}

/// Window ids the accessibility API currently exposes for `pid` as real, raisable document
/// windows. This only ever covers windows on the *current* Space: AX reports an empty or
/// partial window list for windows sitting on other Spaces, even when the app is frontmost.
private func axStandardWindowIDs(ofPID pid: pid_t) -> Set<CGWindowID> {
    guard let axGetWindow = axGetWindow else { return [] }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
                                        kAXWindowsAttribute as CFString, &value) == .success,
          let list = value as? [AXUIElement]
    else { return [] }

    var ids: Set<CGWindowID> = []
    for element in list {
        var id: CGWindowID = 0
        guard axGetWindow(element, &id) == .success else { continue }
        var subrole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
              (subrole as? String) == (kAXStandardWindowSubrole as String)
        else { continue }
        var minimized: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimized) == .success,
           (minimized as? Bool) == true { continue }
        ids.insert(id)
    }
    return ids
}

/// Every window of `pid` worth cycling to, in a stable order.
///
/// Enumeration has to come from CGWindowList, because that is the only source that sees windows
/// on other Spaces, which is the entire point of this tool. AX is then used to reject junk, but
/// only for windows on the current Space, since that is the only place AX has anything to say.
/// For windows elsewhere we fall back to a size heuristic, which is enough to drop the 1x1 and
/// sliver helper windows apps like Chrome create.
///
/// Sorted by window id so cycle order is stable from press to press. CGWindowList order shifts
/// as windows are raised, which would make the cycle jump around instead of advancing.
private func windows(forPID pid: pid_t, _ sky: SkyLight) -> [AppWindow] {
    let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }

    let activeSpace = sky.activeSpace
    let raisable = axStandardWindowIDs(ofPID: pid)

    var result: [AppWindow] = []
    for entry in list {
        guard (entry[kCGWindowLayer as String] as? Int) == 0,
              (entry[kCGWindowOwnerPID as String] as? pid_t) == pid,
              let id = entry[kCGWindowNumber as String] as? CGWindowID,
              let space = sky.space(ofWindow: id)
        else { continue }

        if space == activeSpace {
            // AX can speak for this one, so trust it over any heuristic: it rejects both the
            // sliver windows Chrome exposes and windows that exist but cannot be raised at all
            // (Notes does this), either of which would otherwise wedge the cycle on a press
            // that appears to succeed but moves nothing.
            if !raisable.contains(id) { continue }
        } else if let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let w = bounds["Width"] as? Double, let h = bounds["Height"] as? Double,
                  w < 200 || h < 200 {
            continue
        }

        result.append(AppWindow(id: id,
                                space: space,
                                title: entry[kCGWindowName as String] as? String ?? ""))
    }
    return result.sorted { $0.id < $1.id }
}

private func focusedWindowID(ofPID pid: pid_t) -> CGWindowID? {
    guard let axGetWindow = axGetWindow else { return nil }
    let app = AXUIElementCreateApplication(pid)
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
          let element = focused
    else { return nil }
    var id: CGWindowID = 0
    guard axGetWindow(element as! AXUIElement, &id) == .success else { return nil }
    return id
}

/// Looked up by id at call time rather than held from enumeration, because for a window on
/// another Space the AX element only becomes available once that Space is current.
/// Returns false if the window isn't in the AX list yet.
@discardableResult
private func raise(windowID target: CGWindowID, ofPID pid: pid_t, verbose: Bool = false) -> Bool {
    guard let axGetWindow = axGetWindow else { return false }
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
                                               kAXWindowsAttribute as CFString, &value)
    guard status == .success, let list = value as? [AXUIElement] else { return false }
    for element in list {
        var id: CGWindowID = 0
        guard axGetWindow(element, &id) == .success, id == target else { continue }
        // All three matter: raise changes z-order, main/focused are what actually move keyboard
        // focus. Raising alone leaves kAXFocusedWindow pointing at the old window, so the next
        // press would compute the same "current" window and the cycle would never advance.
        let raised = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        let mained = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        let focused = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if verbose || raised != .success || mained != .success || focused != .success {
            log("  raise wid=\(target): raise=\(raised.rawValue) main=\(mained.rawValue) focused=\(focused.rawValue)")
        }
        return true
    }
    return false
}

/// Activates the app and raises the window, retrying until it shows up.
///
/// A window on another Space is absent from the app's AX list until that Space finishes becoming
/// current, and how long that takes depends on the Space-switch animation. Polling for it beats
/// any fixed delay, which is either too short (the raise silently does nothing and the cycle
/// never advances) or needlessly slow on every press.
private func raiseWhenAvailable(windowID target: CGWindowID,
                                ofPID pid: pid_t,
                                app: NSRunningApplication,
                                verbose: Bool,
                                deadline: Date) {
    app.activate()
    if raise(windowID: target, ofPID: pid, verbose: verbose) { return }
    guard Date() < deadline else {
        log("gave up raising wid=\(target): never appeared in the AX window list")
        return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
        raiseWhenAvailable(windowID: target, ofPID: pid, app: app, verbose: verbose, deadline: deadline)
    }
}

// MARK: - The action

func cycleWindow(_ sky: SkyLight, dryRun: Bool, target: NSRunningApplication? = nil) {
    guard let app = target ?? NSWorkspace.shared.frontmostApplication else { return }
    let pid = app.processIdentifier
    let all = windows(forPID: pid, sky)
    guard all.count > 1 else {
        log("\(app.localizedName ?? "?") has \(all.count) cyclable window(s), nothing to switch to")
        return
    }

    let current = focusedWindowID(ofPID: pid)
    let index = all.firstIndex { $0.id == current } ?? 0
    let next = all[(index + 1) % all.count]
    let activeSpace = sky.activeSpace

    log("\(app.localizedName ?? "?"): \(all.count) windows, current=\(current.map(String.init) ?? "?") "
        + "-> wid=\(next.id) space=\(next.space)\(next.space == activeSpace ? " (same space)" : "") "
        + "\"\(next.title)\"\(dryRun ? " [DRY RUN]" : "")")
    if dryRun { return }

    let verbose = CommandLine.arguments.contains("--verbose")
    func trace(_ what: String) {
        if verbose { log("  [\(what)] activeSpace=\(sky.activeSpace)") }
    }

    if next.space != activeSpace, let target = sky.spaceInfo(id: next.space) {
        sky.switchTo(space: target)
        trace("after switchTo")
    }
    raiseWhenAvailable(windowID: next.id,
                       ofPID: pid,
                       app: app,
                       verbose: verbose,
                       deadline: Date().addingTimeInterval(2.0))
    if verbose {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { trace("+1.0s") }
    }
}


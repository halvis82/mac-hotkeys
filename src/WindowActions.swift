import Cocoa

enum WindowActions {
    /// The window the user is looking at right now.
    static func focusedWindowID() -> CGWindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return focusedWindowID(ofPID: app.processIdentifier)
    }

    static func focusedWindowID(ofPID pid: pid_t) -> CGWindowID? {
        guard let axGetWindow = axGetWindow else { return nil }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement(pid: pid),
                                            kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let element = focused
        else { return nil }
        var id: CGWindowID = 0
        guard axGetWindow(element as! AXUIElement, &id) == .success else { return nil }
        return id
    }

    private static func axElement(for target: CGWindowID, pid: pid_t) -> AXUIElement? {
        guard let axGetWindow = axGetWindow else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement(pid: pid),
                                            kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement]
        else { return nil }
        for element in list {
            var id: CGWindowID = 0
            if axGetWindow(element, &id) == .success, id == target { return element }
        }
        return nil
    }

    @discardableResult
    static func raise(windowID target: CGWindowID, ofPID pid: pid_t) -> Bool {
        guard let element = axElement(for: target, pid: pid) else { return false }
        // Raise alone only changes z-order; main and focused are what move keyboard focus.
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return true
    }

    static func unminimize(windowID target: CGWindowID, ofPID pid: pid_t) {
        guard let element = axElement(for: target, pid: pid) else { return }
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }

    /// True once the window server is actually showing this window.
    ///
    /// This is the signal that a Space transition has finished. `SLSGetActiveSpace` is useless
    /// for that: it reports the new Space about 10ms after the request while the animation runs
    /// for roughly 400ms more, so waiting on it returns immediately and everything that follows
    /// still happens mid-transition.
    private static func isOnScreen(_ id: CGWindowID) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]]
        else { return false }
        return list.contains { ($0[kCGWindowNumber as String] as? CGWindowID) == id }
    }

    /// Switches to the window's Space, waits for the transition to genuinely finish, and only
    /// then brings the app forward.
    ///
    /// The waiting is the whole point. Activating an app while the Space is still animating makes
    /// macOS surface that app on the Space being left behind, which is what dumped a desktop app
    /// on top of whatever fullscreen Space you were on instead of taking you to the desktop.
    static let verbose = CommandLine.arguments.contains("--verbose")
    static func trace(_ what: String, _ sky: SkyLight, _ window: WindowInfo) {
        guard verbose else { return }
        log("  [\(what)] activeSpace=\(sky.activeSpace) windowSpace=\(sky.space(ofWindow: window.id).map(String.init) ?? "none") onScreen=\(isOnScreen(window.id))")
    }

    /// Asks LaunchServices to open the app, which is what clicking its Dock icon does.
    ///
    /// This is the only reliable way to *leave* a fullscreen Space. Both alternatives fail the
    /// same way, verified by screenshot: `SLSManagedDisplaySetCurrentSpace` and plain
    /// `NSRunningApplication.activate()` each leave the fullscreen window on screen and draw the
    /// target window on top of it, rather than travelling to the desktop.
    private static func openLikeDock(pid: pid_t) {
        guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    static func activate(window: WindowInfo, space: SpaceInfo, _ sky: SkyLight) {
        let deadline = Date().addingTimeInterval(2.5)
        trace("commit start, target space \(space.id)", sky, window)

        guard sky.activeSpace != space.id else {
            focusNow(window: window, space: space, sky: sky, deadline: deadline)
            return
        }

        if space.isFullscreen {
            // Moving to a fullscreen Space with the window server directly works cleanly, and
            // it is the only way to pick a *particular* fullscreen window when an app owns
            // several, since LaunchServices would just pick one for us.
            sky.switchTo(space: space)
        } else {
            openLikeDock(pid: window.pid)
        }
        trace("after navigation", sky, window)
        waitForTransition(window: window, space: space, sky: sky, deadline: deadline,
                          settleBy: Date().addingTimeInterval(0.6))
    }

    /// Waits for the target window to appear on screen, which adapts to however long the
    /// animation actually takes. Minimized and Stage-Manager-parked windows never appear on
    /// their own, so `settleBy` bounds the wait for them.
    private static func waitForTransition(window: WindowInfo,
                                          space: SpaceInfo,
                                          sky: SkyLight,
                                          deadline: Date,
                                          settleBy: Date) {
        let arrived = sky.activeSpace == space.id && isOnScreen(window.id)
        let ready = arrived || Date() >= settleBy
        guard ready else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                waitForTransition(window: window, space: space, sky: sky,
                                  deadline: deadline, settleBy: settleBy)
            }
            return
        }
        trace("transition finished, about to activate", sky, window)
        focusNow(window: window, space: space, sky: sky, deadline: deadline)
    }

    private static func focusNow(window: WindowInfo,
                                 space: SpaceInfo,
                                 sky: SkyLight,
                                 deadline: Date) {

        let app = NSRunningApplication(processIdentifier: window.pid)
        if sky.activeSpace == space.id || space.isFullscreen { app?.activate() }
        trace("after activate", sky, window)
        if window.isMinimized {
            unminimize(windowID: window.id, ofPID: window.pid)
        }

        // The window only joins its app's AX list once its Space is settled, so keep trying
        // rather than guessing how long the animation takes. Activation happens once, above:
        // re-activating on every attempt would keep yanking focus for as long as the loop runs,
        // fighting the user if they moved on in the meantime. For the same reason the loop gives
        // up the moment the user leaves the Space we were aiming at.
        func attemptRaise() {
            if raise(windowID: window.id, ofPID: window.pid) { return }
            guard Date() < deadline, sky.activeSpace == space.id else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { attemptRaise() }
        }
        attemptRaise()
    }
}

/// Remembers which windows were used most recently, so opening the switcher can land on the
/// last window you were in. Without this the highlight would start on whichever Space happens
/// to sit next in space order, and tapping Cmd+Tab would no longer flip you back and forth
/// between your last two windows.
final class MRUTracker {
    private var order: [CGWindowID] = []

    init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            // The app has just come forward but may not have settled its focused window yet.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                if let id = WindowActions.focusedWindowID(ofPID: app.processIdentifier) {
                    self?.record(id)
                }
            }
        }
    }

    /// How recently a window was used, lower being more recent. Windows never seen sort last.
    func rank(of id: CGWindowID) -> Int {
        order.firstIndex(of: id) ?? Int.max
    }

    func record(_ id: CGWindowID) {
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
        if order.count > 60 { order.removeLast(order.count - 60) }
    }

    /// Index of the tile holding the most recently used window that isn't the current one,
    /// falling back to the next tile along when there's no history to go on yet.
    func initialSelection(tiles: [Tile], current: CGWindowID?) -> Int {
        for id in order where id != current {
            if let index = tiles.firstIndex(where: { $0.windows.contains { $0.id == id } }) {
                return index
            }
        }
        let currentIndex = current.flatMap { id in
            tiles.firstIndex { $0.windows.contains { $0.id == id } }
        }
        guard let currentIndex = currentIndex, tiles.count > 1 else { return 0 }
        return (currentIndex + 1) % tiles.count
    }

    /// Within a desktop tile, which window the arrow selection should start on.
    func preferredWindowIndex(in windows: [WindowInfo], current: CGWindowID?) -> Int {
        for id in order where id != current {
            if let index = windows.firstIndex(where: { $0.id == id }) { return index }
        }
        return 0
    }
}

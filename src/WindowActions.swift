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
        trace("commit start, target space \(space.id)", sky, window)

        // Already there: nothing to navigate, just focus it.
        guard sky.activeSpace != space.id else {
            focusNow(window: window, space: space, sky: sky, deadline: Date().addingTimeInterval(1.0))
            return
        }

        // Same app, different Space, which is every Cmd+backtick press. Its Window menu is
        // immediate and names the exact window, so there is nothing to wait for.
        let app = NSRunningApplication(processIdentifier: window.pid)
        if app?.isActive == true, selectViaWindowMenu(window: window) {
            trace("navigated via Window menu", sky, window)
            return
        }

        // Another app: activating it is the only thing that can leave a fullscreen Space.
        openLikeDock(pid: window.pid)
        correctWindowOnceFrontmost(window: window, space: space, sky: sky,
                                   deadline: Date().addingTimeInterval(1.5))
    }

    /// Activation brings an app forward on whichever Space holds its most recent window, which
    /// may not be the window that was picked. Once the app is frontmost its Window menu becomes
    /// readable, so the exact window can be reached from there.
    ///
    /// Polled rather than delayed by a fixed amount: waiting a flat half second made every
    /// switch feel slower than the system animation it replaced.
    private static func correctWindowOnceFrontmost(window: WindowInfo,
                                                   space: SpaceInfo,
                                                   sky: SkyLight,
                                                   deadline: Date) {
        if sky.activeSpace == space.id { return } // activation already landed correctly
        guard Date() < deadline else { return }
        if NSRunningApplication(processIdentifier: window.pid)?.isActive == true,
           selectViaWindowMenu(window: window) {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            correctWindowOnceFrontmost(window: window, space: space, sky: sky, deadline: deadline)
        }
    }

    /// Picks a window through its app's own Window menu.
    ///
    /// This exists because `SLSManagedDisplaySetCurrentSpace` cannot be used to *enter* a
    /// fullscreen Space. Doing so leaves that Space half-entered: macOS stops treating it as
    /// properly current, so afterwards nothing can leave it. Activating a desktop app then draws
    /// it on top of the stale fullscreen content while the Space silently refuses to change,
    /// which is the "app opened over my fullscreen window" bug in its final form. Once a Space
    /// is in that state it stays there until the Dock is restarted.
    ///
    /// Going through the Window menu is how macOS itself moves to a window on another fullscreen
    /// Space, and it leaves everything healthy.
    @discardableResult
    private static func selectViaWindowMenu(window: WindowInfo) -> Bool {
        let title = window.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return false }

        let app = appElement(pid: window.pid)
        AXUIElementSetMessagingTimeout(app, 1.0)

        func children(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
            else { return [] }
            return (value as? [AXUIElement]) ?? []
        }
        func label(_ element: AXUIElement) -> String {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success
            else { return "" }
            return (value as? String) ?? ""
        }

        var barValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &barValue) == .success,
              let menuBar = barValue as! AXUIElement?
        else { return false }

        for item in children(menuBar, kAXChildrenAttribute as String) where label(item) == "Window" {
            for menu in children(item, kAXChildrenAttribute as String) {
                for entry in children(menu, kAXChildrenAttribute as String)
                where label(entry).hasPrefix(title) {
                    return AXUIElementPerformAction(entry, kAXPressAction as CFString) == .success
                }
            }
        }
        return false
    }



    /// Raises a window after the desktop is genuinely showing.
    ///
    /// The extra settle on top of the Space check is deliberate: the Space reads as current long
    /// before the transition finishes, and raising during it is what drags windows across.
    private static func raiseOnceSettled(window: WindowInfo, space: SpaceInfo, sky: SkyLight) {
        func attempt(_ remaining: Int) {
            guard sky.activeSpace == space.id else {
                guard remaining > 0 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { attempt(remaining - 1) }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                guard sky.activeSpace == space.id else { return }
                NSRunningApplication(processIdentifier: window.pid)?.activate()
                raise(windowID: window.id, ofPID: window.pid)
            }
        }
        attempt(40)
    }



    private static func focusNow(window: WindowInfo,
                                 space: SpaceInfo,
                                 sky: SkyLight,
                                 deadline: Date) {

        // Only ever reached with the target Space already current, so activating and raising
        // cannot pull the window onto somewhere else.
        let app = NSRunningApplication(processIdentifier: window.pid)
        app?.activate()
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
            // Re-checked every time: if the user has moved to another Space in the meantime,
            // raising would drag this window over to them.
            guard sky.activeSpace == space.id else { return }
            if raise(windowID: window.id, ofPID: window.pid) { return }
            guard Date() < deadline else { return }
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

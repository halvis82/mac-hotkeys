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

    static func activate(window: WindowInfo,
                         space: SpaceInfo,
                         _ sky: SkyLight,
                         completion: ((Bool) -> Void)? = nil) {
        trace("commit start, target space \(space.id)", sky, window)

        // Already there: nothing to navigate, just focus it. Raising by window id is exact, so
        // none of the guessing below is needed.
        guard sky.activeSpace != space.id else {
            focusNow(window: window, space: space, sky: sky, deadline: Date().addingTimeInterval(1.0))
            completion?(true)
            return
        }

        // Same app, different Space, which is every Cmd+backtick press between fullscreen
        // windows. The app is frontmost by definition, so its Window menu is readable and can
        // name the window. Roughly 4ms to find and press.
        let app = NSRunningApplication(processIdentifier: window.pid)
        let entries = app?.isActive == true ? windowMenuEntries(for: window) : []
        if !entries.isEmpty {
            press(entries, from: 0, space: space, sky: sky) { arrived in
                if arrived {
                    trace("navigated via Window menu", sky, window)
                    completion?(true)
                } else {
                    log("Window menu did not reach space \(space.id) for \"\(window.title)\"; "
                        + "falling back to activating the app")
                    activateApp(window: window, space: space, sky: sky, completion: completion)
                }
            }
            return
        }

        activateApp(window: window, space: space, sky: sky, completion: completion)
    }

    /// Bring the app forward and then correct which of its windows is showing.
    ///
    /// Activation is the only thing that can leave a fullscreen Space.
    ///
    /// The window server switch would move instantly instead of spending macOS's ~450ms on the
    /// animation, and that is exactly what this used to do. It cannot be used. Entering a
    /// fullscreen Space that way leaves it half-entered, after which nothing can leave it and
    /// later switches draw windows on top of stale fullscreen content. Three ways of healing it
    /// afterwards were tried and measured: activating the app in place, raising the target window
    /// first and then re-activating, and both combined. Each still ended poisoned within a few
    /// presses. The speed and a working window server turned out to be the same trade, so the
    /// animation stays.
    private static func activateApp(window: WindowInfo,
                                    space: SpaceInfo,
                                    sky: SkyLight,
                                    completion: ((Bool) -> Void)?) {
        openLikeDock(pid: window.pid)
        correctWindowOnceFrontmost(window: window, space: space, sky: sky,
                                   deadline: Date().addingTimeInterval(1.5))
        waitForSpace(space.id, sky: sky, deadline: Date().addingTimeInterval(2.5)) { arrived in
            if !arrived {
                log("could not reach space \(space.id) for \(window.appName) wid=\(window.id)")
            }
            completion?(arrived)
        }
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
        if NSRunningApplication(processIdentifier: window.pid)?.isActive == true {
            let entries = windowMenuEntries(for: window)
            if !entries.isEmpty {
                press(entries, from: 0, space: space, sky: sky) { _ in }
                return
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            correctWindowOnceFrontmost(window: window, space: space, sky: sky, deadline: deadline)
        }
    }

    /// True once the given Space is the current one, or false once we stop waiting.
    ///
    /// How long that takes depends on the direction, which is worth knowing before picking a
    /// deadline. Measured with the window server polled every 10ms: *entering* a fullscreen
    /// Space from the Window menu does not register until about 405ms in, at the end of the
    /// animation. A first attempt at 350ms therefore called a press failed a few tens of
    /// milliseconds before it landed, and fell back to a second route that then fought the
    /// first one.
    private static func waitForSpace(_ id: UInt64,
                                     sky: SkyLight,
                                     deadline: Date,
                                     _ done: @escaping (Bool) -> Void) {
        if sky.activeSpace == id { done(true); return }
        guard Date() < deadline else { done(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            waitForSpace(id, sky: sky, deadline: deadline, done)
        }
    }

    /// Presses Window-menu entries in turn until one actually moves us, because a menu entry is
    /// only ever a guess at which window it stands for.
    ///
    /// Pressing the entry of the window already in front does nothing and looks like nothing, so
    /// a wrong guess costs a moment rather than doing something visibly wrong.
    private static func press(_ entries: [AXUIElement],
                              from index: Int,
                              space: SpaceInfo,
                              sky: SkyLight,
                              _ done: @escaping (Bool) -> Void) {
        guard index < entries.count else { done(false); return }
        guard AXUIElementPerformAction(entries[index], kAXPressAction as CFString) == .success else {
            press(entries, from: index + 1, space: space, sky: sky, done)
            return
        }
        // A second past the measured 405ms, so a busy machine still counts as arrived. Success
        // returns the moment the Space changes, so this only costs anything when a press really
        // did go nowhere, which the checkmark ordering already makes rare.
        waitForSpace(space.id, sky: sky, deadline: Date().addingTimeInterval(1.0)) { arrived in
            if arrived { done(true) }
            else { press(entries, from: index + 1, space: space, sky: sky, done) }
        }
    }

    /// The Window-menu entries that might be the window we want, best candidate first.
    ///
    /// The menu exists because `SLSManagedDisplaySetCurrentSpace` cannot be used to *enter* a
    /// fullscreen Space. Doing so leaves that Space half-entered: macOS stops treating it as
    /// properly current, so afterwards nothing can leave it, and activating a desktop app then
    /// draws it on top of the stale fullscreen content. Once a Space is in that state it stays
    /// there until the Dock is restarted. Going through the Window menu is how macOS itself
    /// moves to a window on another fullscreen Space, and it leaves everything healthy.
    ///
    /// The catch is that a menu offers nothing but titles, and titles are not unique: two empty
    /// Chrome windows are both called "New Tab". Matching on the title alone pressed the same
    /// entry whichever of the two was wanted, so Cmd+backtick worked one way and was a silent
    /// no-op coming back, forever. Two things fix that. A checkmark beside an entry marks the
    /// window the app considers current, which is by definition never where we are going, so
    /// those entries are tried last. And the caller verifies the move instead of assuming it.
    private static func windowMenuEntries(for window: WindowInfo) -> [AXUIElement] {
        let title = window.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return [] }

        let app = appElement(pid: window.pid)
        AXUIElementSetMessagingTimeout(app, 1.0)

        func children(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
            else { return [] }
            return (value as? [AXUIElement]) ?? []
        }
        func string(_ element: AXUIElement, _ attribute: String) -> String {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
            else { return "" }
            return (value as? String) ?? ""
        }

        var barValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &barValue) == .success,
              let menuBar = barValue as! AXUIElement?
        else { return [] }

        var entries: [AXUIElement] = []
        for item in children(menuBar, kAXChildrenAttribute as String)
        where string(item, kAXTitleAttribute as String) == "Window" {
            for menu in children(item, kAXChildrenAttribute as String) {
                entries.append(contentsOf: children(menu, kAXChildrenAttribute as String))
            }
        }

        // Only the last section of the menu, which is where AppKit puts the window list. The rest
        // is commands, and their names collide with real window titles: Chrome's Window menu has
        // a "Downloads" command while a Finder window is often called "Downloads". Searching the
        // whole menu would press the command. Separators come through as empty-titled entries,
        // so the window list is everything past the last one.
        if let lastSeparator = entries.lastIndex(where: { string($0, kAXTitleAttribute as String).isEmpty }) {
            entries = Array(entries[(lastSeparator + 1)...])
        }

        // An entry matches if it starts with the window title, which covers apps that append to
        // it, or if it is the title cut short with an ellipsis, which covers menus truncating a
        // long one. Deliberately not "the title starts with the entry" in general: that would
        // let the Zoom command claim a window called "Zoom Meeting".
        let matches = entries.filter {
            let label = string($0, kAXTitleAttribute as String)
            guard !label.isEmpty else { return false }
            if label.hasPrefix(title) { return true }
            return label.hasSuffix("\u{2026}") && title.hasPrefix(String(label.dropLast()))
        }
        // "AXMenuItemMarkChar" spelled out: the constant is not exposed to Swift.
        let isCurrent = { (entry: AXUIElement) in !string(entry, "AXMenuItemMarkChar").isEmpty }
        let ordered = matches.filter { !isCurrent($0) } + matches.filter(isCurrent)
        if matches.count > 1 {
            log("\(matches.count) Window-menu entries match \"\(title)\"; "
                + "trying the unchecked one first")
        }
        return ordered
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

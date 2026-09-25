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
        let origin = sky.activeSpace
        let start = Date()

        // Straight there. Activation heads for the app's key window, so if the chosen window
        // is not it, it is made key first. Without that, activation went to the app's most recent
        // window and was redirected afterwards, a visible stop at the wrong window on the way.
        // AX can name an app's key window even while it sits on another Space.
        let previous = NSWorkspace.shared.frontmostApplication
        let keyNow = focusedWindowID(ofPID: window.pid)
        if keyNow == window.id {
            if verbose { log("  [route] already the app's key window, activating") }
            openLikeDock(pid: window.pid)
        } else if !window.isMinimized,
                  let previous = previous,
                  // Only handed back to an ordinary app. The hand-back was measured against those;
                  // loginwindow, or a launcher panel like Spotlight's, is not somewhere to park
                  // focus even for a moment, so those take the redirect route instead.
                  previous.activationPolicy == .regular,
                  previous.processIdentifier != window.pid,
                  previous.processIdentifier != getpid(),
                  KeyWindow.makeKey(windowID: window.id, pid: window.pid) {
            if verbose {
                log("  [route] key window was \(keyNow.map(String.init) ?? "unknown"), making \(window.id) key, "
                    + "handing back to \(previous.localizedName ?? "?")")
            }
            // The app takes the new key window when it gets round to the event, so wait until
            // it says so. Handing focus back before then deactivates it with the old key window
            // still key, and activation goes there: the detour this is here to prevent.
            whenKey(window.id, of: window.pid, deadline: start.addingTimeInterval(0.08)) { confirmed in
                if verbose { log("  [route] key window \(confirmed ? "confirmed" : "NOT confirmed") after \(Int(Date().timeIntervalSince(start) * 1000))ms") }
                // Making it key also put the app in front without moving the screen, and the Dock
                // only moves to an app when it sees it *become* active. So focus goes back to where
                // it was for a moment, then the app is activated for real.
                previous.activate()
                whenHandedBack(to: previous, from: window.pid, deadline: Date().addingTimeInterval(0.3)) {
                    if verbose { log("  [route] handed back, activating at \(Int(Date().timeIntervalSince(start) * 1000))ms") }
                    activateUntilFront(pid: window.pid, attempts: 3)
                }
            }
        } else {
            if verbose { log("  [route] no direct route (previous=\(previous?.localizedName ?? "none")), activating") }
            openLikeDock(pid: window.pid)
        }

        // Kept even on the direct route, as the safety net: if activation still ends up on
        // another of the app's windows, this presses the right one in the Window menu.
        correctWindowOnceFrontmost(window: window, space: space, sky: sky, origin: origin,
                                   start: start, deadline: start.addingTimeInterval(1.5))
        // Room for two animations back to back: the one activation starts towards the app's
        // most recent window, and the one the correction then queues behind it.
        waitForSpace(space.id, sky: sky, deadline: start.addingTimeInterval(3.0)) { arrived in
            if !arrived {
                log("could not reach space \(space.id) for \(window.appName) wid=\(window.id)")
            }
            completion?(arrived)
        }
    }

    /// Runs `then` once the app reports `windowID` as its key window, or at the deadline.
    private static func whenKey(_ windowID: CGWindowID,
                                of pid: pid_t,
                                deadline: Date,
                                _ then: @escaping (Bool) -> Void) {
        if focusedWindowID(ofPID: pid) == windowID { then(true); return }
        guard Date() < deadline else { then(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.003) {
            whenKey(windowID, of: pid, deadline: deadline, then)
        }
    }

    /// Runs `then` once focus is back with `previous`, and the Dock has had time to notice.
    ///
    /// Both halves were measured, starting from a fullscreen Space, 21 switches each:
    ///
    /// - Going by AppKit alone (`isActive`, `frontmostApplication`), which trails the window
    ///   server, the hand-back could be declared done while the window server still had the
    ///   target in front, and activating an app already in front does nothing.
    /// - Going by the window server as well, the hand-back is often complete within a
    ///   millisecond, and activating the target at once worked only 12 times in 21. The target
    ///   came to the front every time, but the Space never changed. The Dock, which does the
    ///   switching, learns of app changes a little later, and a target that was in front, left
    ///   and came back within a few milliseconds never looked to it like an app becoming active.
    ///   Waiting 40ms after the hand-back worked 21 of 21, as did 80ms. 50ms is used.
    private static let dockNoticeDelay: TimeInterval = 0.05

    private static func whenHandedBack(to previous: NSRunningApplication,
                                       from target: pid_t,
                                       deadline: Date,
                                       _ then: @escaping () -> Void) {
        let windowServer = KeyWindow.isFront(pid: previous.processIdentifier) != false
        let appKit = previous.isActive
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == previous.processIdentifier
            && NSRunningApplication(processIdentifier: target)?.isActive != true
        if (windowServer && appKit) || Date() >= deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + dockNoticeDelay, execute: then)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.003) {
            whenHandedBack(to: previous, from: target, deadline: deadline, then)
        }
    }

    /// Activates the app the Dock's way and checks the window server took it, asking again if
    /// not. An activation request can be dropped outright, and a dropped one leaves the user
    /// where they were with nothing happening; in successful switches the app is in front within
    /// 30ms, so 150ms without it means it will not come.
    private static func activateUntilFront(pid: pid_t, attempts: Int) {
        openLikeDock(pid: pid)
        guard attempts > 1 else { return }
        let asked = Date()
        func check() {
            if KeyWindow.isFront(pid: pid) != false { return }
            if Date().timeIntervalSince(asked) < 0.15 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: check)
                return
            }
            if verbose { log("  [activation dropped, asking again]") }
            activateUntilFront(pid: pid, attempts: attempts - 1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: check)
    }

    /// Whether activating the app has got as far as deciding where to go.
    ///
    /// The app reports itself active the moment LaunchServices is asked, well before macOS has
    /// started moving to the app's most recent window. A Window-menu press made in that gap is
    /// swallowed: the move to the recent window goes ahead regardless, and the press is lost.
    /// That is what sent Cmd+Tab from the desktop to the *other* Chrome window every time: in
    /// Chrome window A, over to the desktop, then to Chrome window B, landed back on A.
    ///
    /// A press made once the move has begun is queued behind it by macOS, and lands. Measured
    /// both ways, 4 of 4 each: pressing on activation failed every time, pressing once the Space
    /// had started changing worked every time and cost one extra animation. The app's recent
    /// window can also be on the Space we are already on, in which case nothing moves, and that
    /// shows as the app's focused window being here.
    private static func activationHasLanded(pid: pid_t, origin: UInt64, sky: SkyLight) -> Bool {
        let active = sky.activeSpace
        if active != origin { return true }
        return activationHasLanded(activeSpace: active, origin: origin,
                                   focusedWindowSpace: focusedWindowID(ofPID: pid).flatMap(sky.space(ofWindow:)))
    }

    /// The pure half of the above, so the rule can be tested without moving the screen.
    static func activationHasLanded(activeSpace: UInt64, origin: UInt64, focusedWindowSpace: UInt64?) -> Bool {
        activeSpace != origin || focusedWindowSpace == origin
    }

    /// Activation brings an app forward on whichever Space holds its key window. With KeyWindow
    /// that is the window that was picked, but if it could not be used, or macOS went elsewhere
    /// anyway, it is the app's most recent window. Once the app is frontmost its Window menu
    /// becomes readable, so the exact window can be reached from there.
    ///
    /// Polled rather than delayed by a fixed amount: waiting a flat half second made every
    /// switch feel slower than the system animation it replaced. A press that does not arrive is
    /// tried again until the deadline, because a lost press otherwise leaves the user on the
    /// wrong window with nothing left to put it right.
    private static func correctWindowOnceFrontmost(window: WindowInfo,
                                                   space: SpaceInfo,
                                                   sky: SkyLight,
                                                   origin: UInt64,
                                                   start: Date,
                                                   deadline: Date) {
        if sky.activeSpace == space.id { return } // activation already landed correctly
        guard Date() < deadline else { return }
        // If the landing is never seen, press anyway after a while, as this always used to.
        let landed = activationHasLanded(pid: window.pid, origin: origin, sky: sky)
            || Date().timeIntervalSince(start) > 0.8
        if landed, NSRunningApplication(processIdentifier: window.pid)?.isActive == true {
            let entries = windowMenuEntries(for: window)
            if verbose {
                log("  [correct] landed, activeSpace=\(sky.activeSpace), \(entries.count) menu entries for \"\(window.title)\"")
            }
            if !entries.isEmpty {
                press(entries, from: 0, space: space, sky: sky) { arrived in
                    trace("correction press \(arrived ? "arrived" : "did NOT arrive")", sky, window)
                    if !arrived {
                        correctWindowOnceFrontmost(window: window, space: space, sky: sky, origin: origin,
                                                   start: start, deadline: deadline)
                    }
                }
                return
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            correctWindowOnceFrontmost(window: window, space: space, sky: sky, origin: origin,
                                       start: start, deadline: deadline)
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

        let labels = entries.map { string($0, kAXTitleAttribute as String) }
        // "AXMenuItemMarkChar" spelled out: the constant is not exposed to Swift.
        let order = windowMenuCandidates(labels: labels, windowTitle: title) {
            !string(entries[$0], "AXMenuItemMarkChar").isEmpty
        }
        if order.count > 1 {
            log("\(order.count) Window-menu entries match \"\(title)\"; "
                + "trying the unchecked one first")
        }
        return order.map { entries[$0] }
    }

    /// Which Window-menu entries could stand for a window with this title, best first, as
    /// indices into `labels`.
    ///
    /// `isChecked` is asked only about entries that match, since each answer is a round trip
    /// into the app.
    static func windowMenuCandidates(labels: [String],
                                     windowTitle: String,
                                     isChecked: (Int) -> Bool) -> [Int] {
        let title = windowTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return [] }

        // Only the last section of the menu, which is where AppKit puts the window list. The rest
        // is commands, and their names collide with real window titles: Chrome's Window menu has
        // a "Downloads" command while a Finder window is often called "Downloads". Searching the
        // whole menu would press the command. Separators come through as empty-titled entries,
        // so the window list is everything past the last one.
        var range = labels.indices
        if let lastSeparator = labels.lastIndex(where: { $0.isEmpty }) {
            range = (lastSeparator + 1)..<labels.endIndex
        }

        // An entry matches if it starts with the window title, which covers apps that append to
        // it, or if it is the title cut short with an ellipsis, which covers menus truncating a
        // long one. Deliberately not "the title starts with the entry" in general: that would
        // let the Zoom command claim a window called "Zoom Meeting".
        let matches = range.filter { index in
            let label = labels[index]
            guard !label.isEmpty else { return false }
            if label.hasPrefix(title) { return true }
            return label.hasSuffix("\u{2026}") && title.hasPrefix(String(label.dropLast()))
        }
        let checked = Set(matches.filter(isChecked))
        return matches.filter { !checked.contains($0) } + matches.filter { checked.contains($0) }
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

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

    /// Switches to the window's Space, waits for that to actually happen, and only then focuses
    /// the window.
    ///
    /// The waiting is the important part. Activating an app while the Space transition is still
    /// running makes macOS surface that app on the Space being left behind, which is how picking
    /// a desktop app used to dump its window on top of whatever fullscreen Space you were on
    /// instead of taking you to the desktop.
    static func activate(window: WindowInfo, space: SpaceInfo, _ sky: SkyLight) {
        let deadline = Date().addingTimeInterval(2.5)
        if sky.activeSpace != space.id {
            sky.switchTo(space: space)
        }
        focusOnceSpaceIsCurrent(window: window, space: space, sky: sky, deadline: deadline)
    }

    private static func focusOnceSpaceIsCurrent(window: WindowInfo,
                                                space: SpaceInfo,
                                                sky: SkyLight,
                                                deadline: Date) {
        guard sky.activeSpace == space.id || Date() >= deadline else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                focusOnceSpaceIsCurrent(window: window, space: space, sky: sky, deadline: deadline)
            }
            return
        }

        let app = NSRunningApplication(processIdentifier: window.pid)
        app?.activate()
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

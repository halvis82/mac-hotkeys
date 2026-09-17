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

    /// Switches to the window's Space if needed, then focuses it.
    ///
    /// A window on another Space isn't in its app's AX list until that Space finishes becoming
    /// current, so the raise is retried until it lands rather than guessing a fixed delay.
    static func activate(window: WindowInfo, space: SpaceInfo, _ sky: SkyLight) {
        let app = NSRunningApplication(processIdentifier: window.pid)

        if window.isMinimized {
            // A minimized window belongs to no Space, so go to the desktop it will restore
            // onto first, then bring it back before trying to focus it.
            if sky.activeSpace != space.id { sky.switchTo(space: space) }
            app?.activate()
            unminimize(windowID: window.id, ofPID: window.pid)
        } else if sky.activeSpace != space.id {
            sky.switchTo(space: space)
        }

        let deadline = Date().addingTimeInterval(2.0)
        func attempt() {
            app?.activate()
            if raise(windowID: window.id, ofPID: window.pid) { return }
            guard Date() < deadline else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { attempt() }
        }
        attempt()
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

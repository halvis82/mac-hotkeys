import Cocoa

/// One window that can be switched to.
struct WindowInfo {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let bounds: CGRect
    let isMinimized: Bool

    var icon: NSImage? { NSRunningApplication(processIdentifier: pid)?.icon }
}

/// One item in the switcher row.
///
/// A fullscreen Space contributes one tile per window (two in the split-view case). A desktop
/// Space collapses to a single tile no matter how many windows are on it, with those windows
/// reachable via the arrow keys once the tile is selected.
enum Tile {
    case window(space: SpaceInfo, window: WindowInfo)
    case desktop(space: SpaceInfo, windows: [WindowInfo])

    var space: SpaceInfo {
        switch self {
        case .window(let space, _): return space
        case .desktop(let space, _): return space
        }
    }

    var windows: [WindowInfo] {
        switch self {
        case .window(_, let window): return [window]
        case .desktop(_, let windows): return windows
        }
    }

    var isDesktop: Bool {
        if case .desktop = self { return true }
        return false
    }
}

enum WindowLister {
    /// Windows belonging to ordinary apps, which is what filters out the window server's own
    /// furniture: Stage Manager's "Gesture Blocking Overlay", the Dock, Control Center and so
    /// on all run as accessory or prohibited apps rather than regular ones.
    private static func isRegularApp(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
    }

    /// Window ids AX currently vouches for as real, non-minimized document windows.
    /// Only meaningful for the active Space, since AX reports nothing for windows elsewhere.
    static func axStandardWindowIDs(ofPID pid: pid_t) -> Set<CGWindowID> {
        guard let axGetWindow = axGetWindow else { return [] }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement(pid: pid),
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
            ids.insert(id)
        }
        return ids
    }

    /// Minimized windows of an app, which CGWindowList still reports but which have no Space,
    /// so they have to be found through AX and attached to a desktop tile by hand.
    static func minimizedWindowIDs(ofPID pid: pid_t) -> Set<CGWindowID> {
        guard let axGetWindow = axGetWindow else { return [] }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement(pid: pid),
                                            kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement]
        else { return [] }
        var ids: Set<CGWindowID> = []
        for element in list {
            var minimized: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimized) == .success,
                  (minimized as? Bool) == true
            else { continue }
            var id: CGWindowID = 0
            guard axGetWindow(element, &id) == .success else { continue }
            ids.insert(id)
        }
        return ids
    }

    /// Every switchable window, keyed by the Space it lives on. Windows with no Space at all
    /// (minimized ones) come back under `nil`.
    static func allWindows(_ sky: SkyLight) -> [UInt64?: [WindowInfo]] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [:] }

        let activeSpace = sky.activeSpace
        var axCache: [pid_t: Set<CGWindowID>] = [:]
        var minimizedCache: [pid_t: Set<CGWindowID>] = [:]
        var result: [UInt64?: [WindowInfo]] = [:]

        for entry in list {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  isRegularApp(pid)
            else { continue }

            var rect = CGRect.zero
            if let boundsDict = entry[kCGWindowBounds as String] as? [String: Any] {
                CGRectMakeWithDictionaryRepresentation(boundsDict as CFDictionary, &rect)
            }

            let space = sky.space(ofWindow: id)
            let minimized: Bool
            if space == nil {
                if minimizedCache[pid] == nil { minimizedCache[pid] = minimizedWindowIDs(ofPID: pid) }
                minimized = minimizedCache[pid]!.contains(id)
                // No Space and not minimized means a window the window server never placed,
                // which is the swarm of 1x1 and offscreen helpers apps keep around.
                if !minimized { continue }
            } else {
                minimized = false
                if space == activeSpace {
                    // AX can speak for this Space, so let it reject the sliver windows apps
                    // like Chrome expose that look real in CGWindowList but cannot be focused.
                    if axCache[pid] == nil { axCache[pid] = axStandardWindowIDs(ofPID: pid) }
                    if !axCache[pid]!.contains(id) { continue }
                } else if rect.width < 200 || rect.height < 200 {
                    continue
                }
            }

            let info = WindowInfo(id: id,
                                  pid: pid,
                                  appName: entry[kCGWindowOwnerName as String] as? String ?? "",
                                  title: entry[kCGWindowName as String] as? String ?? "",
                                  bounds: rect,
                                  isMinimized: minimized)
            result[space, default: []].append(info)
        }
        return result
    }

    /// The switcher row: Spaces in window-server order, fullscreen ones expanded to a tile per
    /// window, desktop ones collapsed to a single tile. Empty Spaces are skipped so the row
    /// only ever shows places there is actually something to switch to.
    static func buildTiles(_ sky: SkyLight) -> [Tile] {
        let bySpace = allWindows(sky)
        var tiles: [Tile] = []
        var firstDesktopIndex: Int?

        for space in sky.orderedSpaces() {
            var windows = (bySpace[space.id] ?? []).sorted { $0.id < $1.id }
            if space.isFullscreen {
                // A fullscreen Space holds one window, or two side by side in split view, and
                // those fill the screen. Apps still park helper windows there that are large
                // enough to survive a fixed size threshold (Chrome keeps a 941x458 one), so
                // compare against the biggest window on the Space instead of a fixed number.
                // Both halves of a split view are comparable in area, so they both survive.
                let largest = windows.map { $0.bounds.width * $0.bounds.height }.max() ?? 0
                if largest > 0 {
                    windows = windows.filter { $0.bounds.width * $0.bounds.height >= largest * 0.4 }
                }
                for window in windows { tiles.append(.window(space: space, window: window)) }
            } else {
                if firstDesktopIndex == nil { firstDesktopIndex = tiles.count }
                tiles.append(.desktop(space: space, windows: windows))
            }
        }

        // Minimized windows have no Space of their own, so they hang off the first desktop
        // tile, which is where restoring them will put them anyway.
        let orphans = (bySpace[nil] ?? []).sorted { $0.id < $1.id }
        if !orphans.isEmpty, let index = firstDesktopIndex,
           case .desktop(let space, let windows) = tiles[index] {
            tiles[index] = .desktop(space: space, windows: windows + orphans)
        }

        return tiles.filter { !$0.windows.isEmpty }
    }
}

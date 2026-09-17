import Cocoa

/// One window that can be switched to.
struct WindowInfo {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    /// Identifies the app for grouping. Chrome runs several processes and can own windows under
    /// more than one pid, so pid alone would show the same app as several separate icons.
    let appKey: String
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

    private static func appKey(_ pid: pid_t, fallback: String) -> String {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? fallback
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
    static func allWindows(_ sky: SkyLight, onlyPID: pid_t? = nil) -> [UInt64?: [WindowInfo]] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [:] }

        let activeSpace = sky.activeSpace
        var axCache: [pid_t: Set<CGWindowID>] = [:]
        var minimizedCache: [pid_t: Set<CGWindowID>] = [:]
        var result: [UInt64?: [WindowInfo]] = [:]

        for entry in list {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  onlyPID == nil || pid == onlyPID,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  isRegularApp(pid)
            else { continue }

            var rect = CGRect.zero
            if let boundsDict = entry[kCGWindowBounds as String] as? [String: Any] {
                CGRectMakeWithDictionaryRepresentation(boundsDict as CFDictionary, &rect)
            }

            // Deliberately no size test. Stage Manager parks the windows of apps outside the
            // current stage and the window server then reports their *shrunken* bounds: a real
            // 1200x800 VS Code window comes back as 131x140, and Finder windows as 108x131.
            // Filtering on size therefore deletes precisely the windows this is for, leaving
            // only whichever app happens to be in the active stage at full size.
            //
            // Having a Space is the discriminator instead. Every piece of junk apps keep around
            // (1512x33 strips, 64x64 stubs, offscreen 1x1s) is placed on no Space at all, while
            // every genuine window belongs to one.
            let space = sky.space(ofWindow: id)
            let minimized: Bool

            if let space = space {
                minimized = false
                // Accessibility can only speak for the Space that is currently showing, and only
                // when the app actually answers. Where it does, let it veto the sliver windows
                // apps like Chrome expose that look real here but cannot be focused.
                if space == activeSpace {
                    if axCache[pid] == nil { axCache[pid] = axStandardWindowIDs(ofPID: pid) }
                    let vouched = axCache[pid]!
                    if !vouched.isEmpty, !vouched.contains(id) { continue }
                }
            } else {
                // A window the window server has placed on no Space at all is not somewhere the
                // user can be sent. Apps keep plenty of these around: Mail and Messages hold
                // full-size ones open with no visible window at all, and VS Code and Chrome keep
                // several each. Treating them as desktop windows is what put apps in the switcher
                // that had no windows, and worse, made picking one surface it on top of whichever
                // fullscreen Space you happened to be on, because there was no Space to travel to.
                //
                // The sole exception is a genuinely minimized window, which really does belong to
                // the desktop it will restore onto.
                if minimizedCache[pid] == nil { minimizedCache[pid] = minimizedWindowIDs(ofPID: pid) }
                guard minimizedCache[pid]!.contains(id) else { continue }
                minimized = true
            }

            let name = entry[kCGWindowOwnerName as String] as? String ?? ""
            let info = WindowInfo(id: id,
                                  pid: pid,
                                  appName: name,
                                  appKey: appKey(pid, fallback: name.isEmpty ? "pid:\(pid)" : name),
                                  title: entry[kCGWindowName as String] as? String ?? "",
                                  bounds: rect,
                                  isMinimized: minimized)
            result[space, default: []].append(info)
        }
        return result
    }

    /// One entry per app, each standing for that app's most recently used window.
    ///
    /// A desktop can easily hold several windows of the same app, and showing one icon per
    /// window makes the grid a wall of duplicates. Picking an app is understood as "that app's
    /// most recent window", which `recency` decides (lower is more recent).
    /// Apps are ordered by lowest window id so the grid stays put between openings rather than
    /// reshuffling as recency changes.
    private static func oneWindowPerApp(_ windows: [WindowInfo],
                                        recency: (CGWindowID) -> Int) -> [WindowInfo] {
        var best: [String: WindowInfo] = [:]
        for window in windows {
            guard let existing = best[window.appKey] else { best[window.appKey] = window; continue }
            if recency(window.id) < recency(existing.id) { best[window.appKey] = window }
        }
        let firstWindowID = Dictionary(grouping: windows, by: { $0.appKey })
            .mapValues { $0.map(\.id).min() ?? 0 }
        return best.values.sorted { (firstWindowID[$0.appKey] ?? 0) < (firstWindowID[$1.appKey] ?? 0) }
    }

    /// Every switchable window of one app, filtered exactly as the switcher filters them.
    ///
    /// Cmd+backtick used to keep its own copy of this and drifted: it let through the sliver
    /// helper windows apps park on fullscreen Spaces, so cycling could land on a 1512x68 strip
    /// with no title, which cannot be focused and simply wasted a press.
    static func switchableWindows(ofPID pid: pid_t, _ sky: SkyLight) -> [WindowInfo] {
        // Restricted to this app up front. Cmd+backtick only ever cycles one app, and asking the
        // window server which Space every window on the system belongs to costs a round trip per
        // window, which is what made each press feel sluggish.
        let bySpace = allWindows(sky, onlyPID: pid)
        var result: [WindowInfo] = []
        for space in sky.orderedSpaces() {
            var windows = bySpace[space.id] ?? []
            if space.isFullscreen {
                let largest = windows.map { $0.bounds.width * $0.bounds.height }.max() ?? 0
                if largest > 0 {
                    windows = windows.filter { $0.bounds.width * $0.bounds.height >= largest * 0.4 }
                }
            }
            result.append(contentsOf: windows)
        }
        result.append(contentsOf: bySpace[nil] ?? [])
        return result.sorted { $0.id < $1.id }
    }

    /// The switcher row: Spaces in window-server order, fullscreen ones expanded to a tile per
    /// window, desktop ones collapsed to a single tile. Empty Spaces are skipped so the row
    /// only ever shows places there is actually something to switch to.
    static func buildTiles(_ sky: SkyLight, recency: (CGWindowID) -> Int = { _ in Int.max }) -> [Tile] {
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

        // Minimized and Stage-Manager-parked windows have no Space of their own, so they hang
        // off the first desktop tile, which is where activating them puts them anyway.
        let orphans = (bySpace[nil] ?? []).sorted { $0.id < $1.id }
        if !orphans.isEmpty, let index = firstDesktopIndex,
           case .desktop(let space, let windows) = tiles[index] {
            tiles[index] = .desktop(space: space, windows: windows + orphans)
        }

        // Collapse each desktop to one icon per app once every window has been gathered.
        tiles = tiles.map { tile in
            guard case .desktop(let space, let windows) = tile else { return tile }
            return .desktop(space: space, windows: oneWindowPerApp(windows, recency: recency))
        }

        return tiles.filter { !$0.windows.isEmpty }
    }
}

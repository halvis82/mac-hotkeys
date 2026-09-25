import Cocoa

// Frozen copies of the window listing and thumbnails as they were before they were made faster
// (commit 2c4d08e), kept only so the live tests can prove the fast versions give the same
// answers on a real machine. Not used by the app. Do not "fix" these: their whole value is that
// they are the old behavior, line for line.

enum Reference {
    private static func isRegularApp(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
    }

    private static func appKey(_ pid: pid_t, fallback: String) -> String {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? fallback
    }

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

            let space = sky.space(ofWindow: id)
            let minimized: Bool

            if let space = space {
                minimized = false
                if space == activeSpace {
                    if axCache[pid] == nil { axCache[pid] = axStandardWindowIDs(ofPID: pid) }
                    let vouched = axCache[pid]!
                    if !vouched.isEmpty, !vouched.contains(id) { continue }
                }
            } else {
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

    static func switchableWindows(ofPID pid: pid_t, _ sky: SkyLight) -> [WindowInfo] {
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

    static func buildTiles(_ sky: SkyLight, recency: (CGWindowID) -> Int = { _ in Int.max }) -> [Tile] {
        let bySpace = allWindows(sky)
        var tiles: [Tile] = []
        var firstDesktopIndex: Int?

        for space in sky.orderedSpaces() {
            var windows = (bySpace[space.id] ?? []).sorted { $0.id < $1.id }
            if space.isFullscreen {
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

        let orphans = (bySpace[nil] ?? []).sorted { $0.id < $1.id }
        if !orphans.isEmpty, let index = firstDesktopIndex,
           case .desktop(let space, let windows) = tiles[index] {
            tiles[index] = .desktop(space: space, windows: windows + orphans)
        }

        tiles = tiles.map { tile in
            guard case .desktop(let space, let windows) = tile else { return tile }
            return .desktop(space: space, windows: oneWindowPerApp(windows, recency: recency))
        }

        return tiles.filter { !$0.windows.isEmpty }
    }

    // MARK: - Thumbnails

    static func image(for window: WindowInfo, _ sky: SkyLight) -> NSImage? {
        guard let cgImage = sky.capture(windowID: window.id) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func wallpaperWindowID(forSpaceUUID uuid: String) -> CGWindowID? {
        guard !uuid.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for entry in list {
            guard (entry[kCGWindowOwnerName as String] as? String) == "Dock",
                  let name = entry[kCGWindowName as String] as? String,
                  name == "Wallpaper-\(uuid)"
            else { continue }
            return entry[kCGWindowNumber as String] as? CGWindowID
        }
        return nil
    }

    static func desktopPreview(space: SpaceInfo, windows: [WindowInfo], _ sky: SkyLight) -> NSImage? {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let canvas = screen.frame.size

        let result = NSImage(size: canvas)
        result.lockFocus()
        defer { result.unlockFocus() }

        if let wallpaperID = wallpaperWindowID(forSpaceUUID: space.uuid),
           let wallpaper = sky.capture(windowID: wallpaperID) {
            NSImage(cgImage: wallpaper, size: canvas)
                .draw(in: NSRect(origin: .zero, size: canvas))
        } else {
            NSColor.darkGray.setFill()
            NSRect(origin: .zero, size: canvas).fill()
        }

        for window in windows.reversed() where !window.isMinimized {
            guard let capture = sky.capture(windowID: window.id) else { continue }
            let rect = NSRect(x: window.bounds.origin.x,
                              y: canvas.height - window.bounds.origin.y - window.bounds.height,
                              width: window.bounds.width,
                              height: window.bounds.height)
            NSImage(cgImage: capture, size: rect.size).draw(in: rect)
        }

        return result
    }
}

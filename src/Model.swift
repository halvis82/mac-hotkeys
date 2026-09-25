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

    var icon: NSImage? { AppIcons.icon(forPID: pid) }
}

/// `NSRunningApplication` for a pid, kept rather than looked up afresh on every open.
///
/// Creating one asks LaunchServices about the process, about 60 microseconds a time, and every
/// open needs one for each of the fifty or so processes owning a window: around 3ms of the
/// keystroke path. A kept instance still answers `activationPolicy` live, since AppKit keeps
/// running-application objects up to date. Dropped when the process quits, as a pid can be
/// reused by a later app. Processes that are not apps at all get nil, and are asked again each
/// time since that is cheap to find out.
enum RunningApps {
    private static let lock = NSLock()
    private static var cache: [pid_t: NSRunningApplication] = [:]
    private static let observer: NSObjectProtocol = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil
    ) { note in
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        forget(pid: app.processIdentifier)
    }

    static func app(forPID pid: pid_t) -> NSRunningApplication? {
        _ = observer
        lock.lock()
        if let app = cache[pid] {
            lock.unlock()
            // Belt and braces for a quit whose notification has not arrived yet.
            if !app.isTerminated { return app }
            forget(pid: pid)
        } else {
            lock.unlock()
        }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        lock.lock()
        cache[pid] = app
        lock.unlock()
        return app
    }

    static func forget(pid: pid_t) {
        lock.lock()
        cache[pid] = nil
        lock.unlock()
    }
}

/// App icons, looked up once per app rather than on every draw.
///
/// The switcher redraws every tile on each Tab press, and each draw asked LaunchServices for the
/// app behind every window again. Icons belong to the process, so they are dropped when it quits:
/// a pid can be reused by a later app.
enum AppIcons {
    private static let lock = NSLock()
    private static var cache: [pid_t: NSImage] = [:]
    private static let observer: NSObjectProtocol = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil
    ) { note in
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        forget(pid: app.processIdentifier)
    }

    static func icon(forPID pid: pid_t) -> NSImage? {
        _ = observer
        lock.lock()
        if let icon = cache[pid] { lock.unlock(); return icon }
        lock.unlock()
        // Looked up outside the lock: LaunchServices can take a moment on first sight of an app.
        guard let icon = NSRunningApplication(processIdentifier: pid)?.icon else { return nil }
        lock.lock()
        cache[pid] = icon
        lock.unlock()
        return icon
    }

    static func forget(pid: pid_t) {
        lock.lock()
        cache[pid] = nil
        lock.unlock()
    }
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
    /// Window ids AX currently vouches for as real, non-minimized document windows.
    /// Only meaningful for the active Space, since AX reports nothing for windows elsewhere.
    static func axStandardWindowIDs(ofPID pid: pid_t) -> Set<CGWindowID> {
        axWindowFacts(ofPID: pid, standard: true, minimized: false).standard
    }

    /// Minimized windows of an app, which CGWindowList still reports but which have no Space,
    /// so they have to be found through AX and attached to a desktop tile by hand.
    static func minimizedWindowIDs(ofPID pid: pid_t) -> Set<CGWindowID> {
        axWindowFacts(ofPID: pid, standard: false, minimized: true).minimized
    }

    /// Both of the above from a single read of the app's window list.
    ///
    /// Every AX call is a round trip into the app, so an app with windows on the current Space
    /// and minimized ones as well used to be asked for its window list twice.
    static func axWindowFacts(ofPID pid: pid_t,
                              standard wantStandard: Bool,
                              minimized wantMinimized: Bool)
        -> (standard: Set<CGWindowID>, minimized: Set<CGWindowID>) {
        guard let axGetWindow = axGetWindow, wantStandard || wantMinimized else { return ([], []) }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement(pid: pid),
                                            kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement]
        else { return ([], []) }
        var standard: Set<CGWindowID> = []
        var minimized: Set<CGWindowID> = []
        for element in list {
            var id: CGWindowID = 0
            guard axGetWindow(element, &id) == .success else { continue }
            if wantStandard {
                var subrole: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
                   (subrole as? String) == (kAXStandardWindowSubrole as String) {
                    standard.insert(id)
                }
            }
            if wantMinimized {
                var isMinimized: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &isMinimized) == .success,
                   (isMinimized as? Bool) == true {
                    minimized.insert(id)
                }
            }
        }
        return (standard, minimized)
    }

    /// Whether a window belongs in the switcher, and as what.
    enum Admission: Equatable {
        case skip
        case onSpace
        case minimized
    }

    /// The rule that decides which windows are real.
    ///
    /// `vouched` is the app's AX-standard window set, looked at only for windows on the active
    /// Space. `minimized` is the app's AX-minimized set, looked at only for windows with no Space.
    static func admission(of id: CGWindowID,
                          space: UInt64?,
                          activeSpace: UInt64,
                          vouched: Set<CGWindowID>,
                          minimized: Set<CGWindowID>) -> Admission {
        // Deliberately no size test. Stage Manager parks the windows of apps outside the
        // current stage and the window server then reports their *shrunken* bounds: a real
        // 1200x800 VS Code window comes back as 131x140, and Finder windows as 108x131.
        // Filtering on size therefore deletes precisely the windows this is for, leaving
        // only whichever app happens to be in the active stage at full size.
        //
        // Having a Space is the discriminator instead. Every piece of junk apps keep around
        // (1512x33 strips, 64x64 stubs, offscreen 1x1s) is placed on no Space at all, while
        // every genuine window belongs to one.
        if let space = space {
            // Accessibility can only speak for the Space that is currently showing, and only
            // when the app actually answers. Where it does, let it veto the sliver windows
            // apps like Chrome expose that look real here but cannot be focused.
            if space == activeSpace, !vouched.isEmpty, !vouched.contains(id) { return .skip }
            return .onSpace
        }
        // A window the window server has placed on no Space at all is not somewhere the
        // user can be sent. Apps keep plenty of these around: Mail and Messages hold
        // full-size ones open with no visible window at all, and VS Code and Chrome keep
        // several each. Treating them as desktop windows is what put apps in the switcher
        // that had no windows, and worse, made picking one surface it on top of whichever
        // fullscreen Space you happened to be on, because there was no Space to travel to.
        //
        // The sole exception is a genuinely minimized window, which really does belong to
        // the desktop it will restore onto.
        return minimized.contains(id) ? .minimized : .skip
    }

    /// Every switchable window, keyed by the Space it lives on. Windows with no Space at all
    /// (minimized ones) come back under `nil`.
    ///
    /// This sits on the keystroke path, between Cmd+Tab and the switcher appearing, so it is
    /// arranged around what is slow. Asking LaunchServices about a pid is surprisingly costly
    /// and used to happen twice per window, around a hundred and fifty times per open, for a
    /// dozen or so distinct apps, so each app is looked up once. The AX questions go to each
    /// app in parallel, because every one is a round trip into that app's process and asking
    /// them in turn made the total the *sum* of every app's response time. One slow app used
    /// to add its delay to everyone else's.
    static func allWindows(_ sky: SkyLight, onlyPID: pid_t? = nil) -> [UInt64?: [WindowInfo]] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        // Read as NSDictionary rather than bridged to [[String: Any]]: bridging converts every
        // key of every window on the system up front, and most windows are thrown away after
        // reading one or two of them.
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as NSArray? else { return [:] }

        let activeSpace = sky.activeSpace
        // Which Space each window is on, asked per Space rather than per window: 5 round trips
        // instead of one for each of 50 to 100 windows, most of them apps' hidden helpers on no
        // Space at all. Measured against `space(ofWindow:)` over every window on the system, 20
        // times: all 1380 placements agreed, and of 2360 windows missing from every Space, the
        // only one the per-window query placed was Finder's desktop-icon window, which is not on
        // layer 0 and never gets here. A window on several Spaces is still asked about directly,
        // and the live tests re-check all of this every run.
        let membership = sky.spaces(ofWindowsOn: sky.orderedSpaces().map(\.id))
        func spaceOf(_ id: CGWindowID) -> UInt64? {
            guard let membership = membership else { return sky.space(ofWindow: id) }
            guard let spaces = membership[id] else { return nil }
            return spaces.count == 1 ? spaces[0] : sky.space(ofWindow: id)
        }

        struct AppFacts {
            let isRegular: Bool
            let bundleID: String?
        }
        struct Candidate {
            let entry: NSDictionary
            let id: CGWindowID
            let pid: pid_t
            let space: UInt64?
        }
        var apps: [pid_t: AppFacts] = [:]
        var candidates: [Candidate] = []
        var needsStandard: Set<pid_t> = []
        var needsMinimized: Set<pid_t> = []

        for case let entry as NSDictionary in list {
            guard (entry[kCGWindowLayer] as? Int) == 0,
                  let pid = entry[kCGWindowOwnerPID] as? pid_t,
                  onlyPID == nil || pid == onlyPID,
                  let id = entry[kCGWindowNumber] as? CGWindowID
            else { continue }

            // Windows belonging to ordinary apps, which is what filters out the window server's
            // own furniture: Stage Manager's "Gesture Blocking Overlay", the Dock, Control
            // Center and so on all run as accessory or prohibited apps rather than regular ones.
            let app: AppFacts
            if let known = apps[pid] {
                app = known
            } else {
                let running = RunningApps.app(forPID: pid)
                app = AppFacts(isRegular: running?.activationPolicy == .regular,
                               bundleID: running?.bundleIdentifier)
                apps[pid] = app
            }
            guard app.isRegular else { continue }

            let space = spaceOf(id)
            if let space = space {
                if space == activeSpace { needsStandard.insert(pid) }
            } else {
                needsMinimized.insert(pid)
            }
            candidates.append(Candidate(entry: entry, id: id, pid: pid, space: space))
        }

        let facts = axWindowFacts(standardFor: needsStandard, minimizedFor: needsMinimized)

        var result: [UInt64?: [WindowInfo]] = [:]
        for candidate in candidates {
            let pidFacts = facts[candidate.pid]
            let verdict = admission(of: candidate.id,
                                    space: candidate.space,
                                    activeSpace: activeSpace,
                                    vouched: pidFacts?.standard ?? [],
                                    minimized: pidFacts?.minimized ?? [])
            guard verdict != .skip else { continue }

            let entry = candidate.entry
            var rect = CGRect.zero
            if let boundsDict = entry[kCGWindowBounds] as? NSDictionary {
                CGRectMakeWithDictionaryRepresentation(boundsDict as CFDictionary, &rect)
            }
            let name = entry[kCGWindowOwnerName] as? String ?? ""
            let fallbackKey = name.isEmpty ? "pid:\(candidate.pid)" : name
            let info = WindowInfo(id: candidate.id,
                                  pid: candidate.pid,
                                  appName: name,
                                  appKey: apps[candidate.pid]?.bundleID ?? fallbackKey,
                                  title: entry[kCGWindowName] as? String ?? "",
                                  bounds: rect,
                                  isMinimized: verdict == .minimized)
            result[candidate.space, default: []].append(info)
        }
        return result
    }

    /// AX facts for several apps at once, each app asked on its own thread.
    ///
    /// Apps are separate processes answering separate connections, so there is nothing to
    /// serialize on, and each call already has a short messaging timeout of its own.
    static func axWindowFacts(standardFor standardPIDs: Set<pid_t>,
                              minimizedFor minimizedPIDs: Set<pid_t>)
        -> [pid_t: (standard: Set<CGWindowID>, minimized: Set<CGWindowID>)] {
        let pids = Array(standardPIDs.union(minimizedPIDs))
        guard !pids.isEmpty else { return [:] }
        var answers = [(standard: Set<CGWindowID>, minimized: Set<CGWindowID>)](
            repeating: ([], []), count: pids.count)
        answers.withUnsafeMutableBufferPointer { slots in
            let slots = slots
            DispatchQueue.concurrentPerform(iterations: pids.count) { index in
                let pid = pids[index]
                slots[index] = axWindowFacts(ofPID: pid,
                                             standard: standardPIDs.contains(pid),
                                             minimized: minimizedPIDs.contains(pid))
            }
        }
        return Dictionary(uniqueKeysWithValues: zip(pids, answers))
    }

    /// One entry per app, each standing for that app's most recently used window.
    ///
    /// A desktop can easily hold several windows of the same app, and showing one icon per
    /// window makes the grid a wall of duplicates. Picking an app is understood as "that app's
    /// most recent window", which `recency` decides (lower is more recent).
    /// Apps are ordered by lowest window id so the grid stays put between openings rather than
    /// reshuffling as recency changes.
    static func oneWindowPerApp(_ windows: [WindowInfo],
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

    /// The windows on a fullscreen Space worth a tile, in the order given.
    ///
    /// A fullscreen Space holds one window, or two side by side in split view, and those fill
    /// the screen. Apps still park helper windows there that are large enough to survive a fixed
    /// size threshold (Chrome keeps a 941x458 one), so compare against the biggest window on the
    /// Space instead of a fixed number. Both halves of a split view are comparable in area, so
    /// they both survive.
    static func mainWindows(onFullscreenSpace windows: [WindowInfo]) -> [WindowInfo] {
        let largest = windows.map { $0.bounds.width * $0.bounds.height }.max() ?? 0
        guard largest > 0 else { return windows }
        return windows.filter { $0.bounds.width * $0.bounds.height >= largest * 0.4 }
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
        return cyclableWindows(spaces: sky.orderedSpaces(), bySpace: bySpace)
    }

    /// The pure half of `switchableWindows`: which of the listed windows can be cycled to.
    static func cyclableWindows(spaces: [SpaceInfo], bySpace: [UInt64?: [WindowInfo]]) -> [WindowInfo] {
        var result: [WindowInfo] = []
        for space in spaces {
            let windows = bySpace[space.id] ?? []
            result.append(contentsOf: space.isFullscreen ? mainWindows(onFullscreenSpace: windows) : windows)
        }
        result.append(contentsOf: bySpace[nil] ?? [])
        return result.sorted { $0.id < $1.id }
    }

    /// The switcher row: Spaces in window-server order, fullscreen ones expanded to a tile per
    /// window, desktop ones collapsed to a single tile. Empty Spaces are skipped so the row
    /// only ever shows places there is actually something to switch to.
    static func buildTiles(_ sky: SkyLight,
                           recency: @escaping (CGWindowID) -> Int = { _ in Int.max },
                           preferKeyWindows: Bool = true) -> [Tile] {
        let bySpace = allWindows(sky)
        let spaces = sky.orderedSpaces()
        guard preferKeyWindows else {
            return assembleTiles(spaces: spaces, bySpace: bySpace, recency: recency)
        }
        // Only desktops collapse to one window per app, so only their apps need asking.
        let desktops = Set(spaces.filter { !$0.isFullscreen }.map(\.id))
        let pids = Set(bySpace.filter { $0.key.map(desktops.contains) ?? true }.flatMap { $0.value.map(\.pid) })
        let keys = keyWindows(ofPIDs: pids)
        return assembleTiles(spaces: spaces, bySpace: bySpace,
                             recency: preferring(keyWindows: keys, over: recency))
    }

    /// Recency with each app's key window ranked ahead of everything.
    ///
    /// A desktop tile shows one window per app and stands for that app's most recent window. The
    /// switcher's own history only learns of a window when an app is switched to, so it misses
    /// every change of window *inside* an app: with two Messages windows open, the tile said
    /// "General" long after the other chat had been used, and picking it landed on the chat
    /// anyway, since activating an app goes to its key window. The key window is, by definition,
    /// the app's most recently used one, so it decides, and the tile names the window you get.
    static func preferring(keyWindows: Set<CGWindowID>,
                           over recency: @escaping (CGWindowID) -> Int) -> (CGWindowID) -> Int {
        { keyWindows.contains($0) ? -1 : recency($0) }
    }

    /// The key window of each app, asked in parallel. AX answers this even for an app in the
    /// background whose key window is on another Space.
    static func keyWindows(ofPIDs pids: Set<pid_t>) -> Set<CGWindowID> {
        let list = Array(pids)
        guard !list.isEmpty else { return [] }
        var answers = [CGWindowID?](repeating: nil, count: list.count)
        answers.withUnsafeMutableBufferPointer { slots in
            let slots = slots
            DispatchQueue.concurrentPerform(iterations: list.count) { index in
                slots[index] = WindowActions.focusedWindowID(ofPID: list[index])
            }
        }
        return Set(answers.compactMap { $0 })
    }

    /// The pure half of `buildTiles`, which turns listed windows into the row.
    static func assembleTiles(spaces: [SpaceInfo],
                              bySpace: [UInt64?: [WindowInfo]],
                              recency: (CGWindowID) -> Int) -> [Tile] {
        var tiles: [Tile] = []
        var firstDesktopIndex: Int?

        for space in spaces {
            let windows = (bySpace[space.id] ?? []).sorted { $0.id < $1.id }
            if space.isFullscreen {
                for window in mainWindows(onFullscreenSpace: windows) {
                    tiles.append(.window(space: space, window: window))
                }
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

import Cocoa

/// What the switcher is showing and what is picked, with nothing to do with drawing or windows.
///
/// Kept separate so every selection rule can be tested with made-up tiles. The controller owns
/// one of these while the switcher is up and hands its state to the panel after every change.
struct SwitcherModel {
    private(set) var tiles: [Tile] = []
    private(set) var selected = 0
    /// Which window inside a desktop tile is picked, keyed by Space id.
    private(set) var desktopSelection: [UInt64: Int] = [:]

    init() {}

    /// The state the switcher opens in.
    init(tiles: [Tile], current: CGWindowID?, mru: MRUTracker, backwards: Bool) {
        self.tiles = tiles
        selected = mru.initialSelection(tiles: tiles, current: current)
        if backwards, !tiles.isEmpty {
            // Opening with Shift held means "go the other way", so start one step back from
            // where the user is rather than from the recency pick.
            let currentIndex = current.flatMap { id in
                tiles.firstIndex { $0.windows.contains { $0.id == id } }
            } ?? 0
            selected = (currentIndex - 1 + tiles.count) % tiles.count
        }
        for tile in tiles {
            if case .desktop(let space, let windows) = tile {
                desktopSelection[space.id] = mru.preferredWindowIndex(in: windows, current: current)
            }
        }
    }

    /// Tab and Shift+Tab, wrapping at both ends.
    mutating func advance(by step: Int) -> Bool {
        guard !tiles.isEmpty else { return false }
        selected = ((selected + step) % tiles.count + tiles.count) % tiles.count
        return true
    }

    /// Arrow keys only do anything on a desktop tile, where they pick which of that desktop's
    /// windows will be focused, and they stop at the ends rather than spilling into the next
    /// tile.
    mutating func moveWithinDesktop(by step: Int) -> Bool {
        guard selected < tiles.count,
              case .desktop(let space, let windows) = tiles[selected],
              windows.count > 1
        else { return false }
        let current = desktopSelection[space.id] ?? 0
        desktopSelection[space.id] = min(max(current + step, 0), windows.count - 1)
        return true
    }

    /// Jumps straight to the tile with the given number, as printed under its icon.
    mutating func select(position: Int) -> Bool {
        guard tiles.indices.contains(position) else { return false }
        selected = position
        return true
    }

    /// Mouse selection: a tile, and optionally which icon inside a desktop tile.
    mutating func point(atTile tile: Int, icon: Int?) -> Bool {
        guard tiles.indices.contains(tile) else { return false }
        selected = tile
        if let icon = icon, case .desktop(let space, let windows) = tiles[tile],
           windows.indices.contains(icon) {
            desktopSelection[space.id] = icon
        }
        return true
    }

    /// Which of a desktop's windows is picked, for the verbose log.
    func desktopIndex(ofSpace id: UInt64) -> Int? { desktopSelection[id] }

    /// The window that would be activated right now.
    var currentWindow: WindowInfo? {
        guard selected < tiles.count else { return nil }
        switch tiles[selected] {
        case .window(_, let window):
            return window
        case .desktop(let space, let windows):
            let index = desktopSelection[space.id] ?? 0
            return windows.indices.contains(index) ? windows[index] : windows.first
        }
    }
}

/// Drives the switcher: builds the row when Cmd+Tab opens it, tracks the highlight while Cmd
/// is held, and acts on the selection when Cmd is let go.
final class SwitcherController {
    private let sky: SkyLight
    private var panel = OverlayPanel()
    private let mru = MRUTracker()

    private var model = SwitcherModel()
    private(set) var isOpen = false
    private let verbose = CommandLine.arguments.contains("--verbose")
    private var openedAtWindow: CGWindowID?
    /// Bumped on every open, so a thumbnail still being captured for an earlier open can't
    /// land in this one.
    private var generation = 0
    /// The last thumbnail of each window and preview of each desktop, shown the instant the
    /// switcher opens and replaced by fresh captures moments later. Without them every open
    /// began with blank cards that filled in one by one, which read as the switcher lagging.
    private var lastThumbnails: [CGWindowID: NSImage] = [:]
    private var lastDesktopPreviews: [UInt64: NSImage] = [:]

    init(sky: SkyLight) {
        self.sky = sky
        wirePanel()
    }

    private func wirePanel() {
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.switcherView.onHover = { [weak self] tile, icon in
            self?.point(atTile: tile, icon: icon, commit: false)
        }
        panel.switcherView.onClick = { [weak self] tile, icon in
            self?.point(atTile: tile, icon: icon, commit: true)
        }
    }

    private func rebuildPanel() {
        panel.dismiss()
        panel = OverlayPanel()
        wirePanel()
    }

    private func refreshPanel() {
        panel.refresh(selected: model.selected, desktopSelection: model.desktopSelection)
    }

    /// Mouse selection. Hovering moves the highlight, clicking takes it.
    private func point(atTile tile: Int, icon: Int?, commit shouldCommit: Bool) {
        guard isOpen, model.point(atTile: tile, icon: icon) else { return }
        refreshPanel()
        if shouldCommit { commit() }
    }

    func open(backwards: Bool) {
        let current = WindowActions.focusedWindowID()
        if let current = current { mru.record(current) }

        let tiles = WindowLister.buildTiles(sky, recency: { [mru] in mru.rank(of: $0) })
        guard !tiles.isEmpty else { return }

        openedAtWindow = current
        model = SwitcherModel(tiles: tiles, current: current, mru: mru, backwards: backwards)

        // A fresh panel every time, rather than nursing one along.
        //
        // The reused panel kept ending up invisible while reporting itself perfectly healthy: a
        // full-screen, opaque, listed window that simply never appeared, which is the menu
        // failing to show, most often when opening from a fullscreen Space. The window server
        // said why. A panel that joins every Space should belong to none of them, and the
        // reused one was reported as tied to a single Space on nearly every open, so from
        // anywhere else there was nothing to see. Re-applying the collection behavior did not
        // shake it loose. A panel built fresh is reported on no Space, every time.
        rebuildPanel()
        isOpen = true
        generation += 1
        seedThumbnails()
        panel.present(tiles: model.tiles, selected: model.selected, desktopSelection: model.desktopSelection)
        // One line per open. `winSpace` is the one that matters: anything other than "none"
        // means the overlay has been tied to a single Space and will be invisible from the
        // others, which is what the menu-not-appearing bug looked like.
        log("open: \(tiles.count) tiles, sel \(model.selected + 1), win=\(panel.windowNumber), "
            + "winSpace=\(sky.space(ofWindow: CGWindowID(panel.windowNumber)).map(String.init) ?? "none")")
        loadThumbnails()
    }

    /// Puts the last known pictures in place before the panel is shown, and forgets any for
    /// windows and desktops that are no longer in the row.
    private func seedThumbnails() {
        let windowIDs = Set(model.tiles.compactMap { tile -> CGWindowID? in
            if case .window(_, let window) = tile { return window.id }
            return nil
        })
        let desktopIDs = Set(model.tiles.filter(\.isDesktop).map(\.space.id))
        lastThumbnails = lastThumbnails.filter { windowIDs.contains($0.key) }
        lastDesktopPreviews = lastDesktopPreviews.filter { desktopIDs.contains($0.key) }
        panel.switcherView.thumbnails = lastThumbnails
        panel.switcherView.desktopPreviews = lastDesktopPreviews
    }

    /// Thumbnails are captured off the main thread and dropped in as they arrive, so the
    /// overlay appears immediately instead of waiting on the window server.
    ///
    /// Every tile is captured at once rather than left to right. In turn, the last tile waited
    /// for every capture before it, and a desktop tile alone took over 100ms.
    private func loadThumbnails() {
        let snapshot = model.tiles
        let generation = self.generation
        let view = panel.switcherView
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let backing = screen.backingScaleFactor
        let cover = CGSize(width: view.tileWidth * backing, height: SwitcherView.tileHeight * backing)
        let canvas = screen.frame.size
        let sky = self.sky

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            Thumbnails.ensureScreenRecordingRequested()
            DispatchQueue.concurrentPerform(iterations: snapshot.count) { index in
                switch snapshot[index] {
                case .window(_, let window):
                    let image = Thumbnails.image(for: window, sky, cover: cover)
                    if image == nil {
                        log("capture returned nothing for \(window.appName) wid=\(window.id)"
                            + " - Screen Recording permission is the usual cause")
                    }
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        if let image = image { self.lastThumbnails[window.id] = image }
                        guard self.isOpen, self.generation == generation else { return }
                        self.panel.switcherView.thumbnails[window.id] = image ?? self.lastThumbnails[window.id]
                        self.panel.switcherView.needsDisplay = true
                    }
                case .desktop(let space, let windows):
                    let image = Thumbnails.desktopPreview(space: space, windows: windows, sky,
                                                          canvas: canvas, cover: cover)
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        if let image = image { self.lastDesktopPreviews[space.id] = image }
                        guard self.isOpen, self.generation == generation else { return }
                        self.panel.switcherView.desktopPreviews[space.id] = image ?? self.lastDesktopPreviews[space.id]
                        self.panel.switcherView.needsDisplay = true
                    }
                }
            }
        }
    }

    func advance(by step: Int) {
        guard isOpen, model.advance(by: step) else { return }
        if verbose {
            log("advance \(step > 0 ? "forward" : "back") -> tile \(model.selected + 1)/\(model.tiles.count)")
        }
        refreshPanel()
    }

    /// Arrow keys only do anything on a desktop tile, where they pick which of that desktop's
    /// windows will be focused, and they stop at the ends rather than spilling into the next
    /// tile.
    func moveWithinDesktop(by step: Int) {
        guard isOpen, model.moveWithinDesktop(by: step) else { return }
        if verbose, case .desktop(let space, let windows) = model.tiles[model.selected] {
            log("desktop arrow -> window \((model.desktopIndex(ofSpace: space.id) ?? 0) + 1)/\(windows.count)")
        }
        refreshPanel()
    }

    /// Jumps straight to the tile with the given number, as printed under its icon. The
    /// selection still commits on releasing Command, so a mistyped number can be corrected
    /// with another number, Tab, or Escape.
    func select(position: Int) {
        guard isOpen, model.select(position: position) else { return }
        if verbose { log("number key -> tile \(position + 1)/\(model.tiles.count)") }
        refreshPanel()
    }

    func cancel() {
        guard isOpen else { return }
        if verbose { log("cancelled, staying put") }
        isOpen = false
        panel.dismiss()
    }

    func commit() {
        guard isOpen else { return }
        isOpen = false
        panel.dismiss()

        guard model.selected < model.tiles.count else { return }
        let tile = model.tiles[model.selected]
        guard let window = model.currentWindow else { return }
        if window.id == openedAtWindow { return } // already there, nothing to do

        if verbose { log("commit -> \(window.appName) wid=\(window.id) space=\(tile.space.id)") }
        mru.record(window.id)

        // One run-loop turn, so the overlay is off screen before anything moves Spaces. The
        // panel joins every Space and sits above fullscreen windows; starting a Space change
        // while it is still up left the window server drawing the Space we came from. A hop is
        // enough to separate them, and unlike a timed delay it costs nothing perceptible.
        let sky = self.sky
        DispatchQueue.main.async {
            WindowActions.activate(window: window, space: tile.space, sky)
        }
    }
}

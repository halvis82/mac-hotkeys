import Cocoa

/// Drives the switcher: builds the row when Cmd+Tab opens it, tracks the highlight while Cmd
/// is held, and acts on the selection when Cmd is let go.
final class SwitcherController {
    private let sky: SkyLight
    private let panel = OverlayPanel()
    private let mru = MRUTracker()

    private var tiles: [Tile] = []
    private var selected = 0
    private var desktopSelection: [UInt64: Int] = [:]
    private(set) var isOpen = false
    private let verbose = CommandLine.arguments.contains("--verbose")
    private var openedAtWindow: CGWindowID?

    init(sky: SkyLight) {
        self.sky = sky

        panel.onCancel = { [weak self] in self?.cancel() }
        panel.switcherView.onHover = { [weak self] tile, icon in
            self?.point(atTile: tile, icon: icon, commit: false)
        }
        panel.switcherView.onClick = { [weak self] tile, icon in
            self?.point(atTile: tile, icon: icon, commit: true)
        }
    }

    /// Mouse selection. Hovering moves the highlight, clicking takes it.
    private func point(atTile tile: Int, icon: Int?, commit shouldCommit: Bool) {
        guard isOpen, tiles.indices.contains(tile) else { return }
        selected = tile
        if let icon = icon, case .desktop(let space, let windows) = tiles[tile],
           windows.indices.contains(icon) {
            desktopSelection[space.id] = icon
        }
        panel.refresh(selected: selected, desktopSelection: desktopSelection)
        if shouldCommit { commit() }
    }

    func open(backwards: Bool) {
        let current = WindowActions.focusedWindowID()
        if let current = current { mru.record(current) }

        tiles = WindowLister.buildTiles(sky, recency: { [mru] in mru.rank(of: $0) })
        guard !tiles.isEmpty else { return }

        openedAtWindow = current
        selected = mru.initialSelection(tiles: tiles, current: current)
        if backwards {
            // Opening with Shift held means "go the other way", so start one step back from
            // where the user is rather than from the recency pick.
            let currentIndex = current.flatMap { id in
                tiles.firstIndex { $0.windows.contains { $0.id == id } }
            } ?? 0
            selected = (currentIndex - 1 + tiles.count) % tiles.count
        }

        desktopSelection = [:]
        for tile in tiles {
            if case .desktop(let space, let windows) = tile {
                desktopSelection[space.id] = mru.preferredWindowIndex(in: windows, current: current)
            }
        }

        if verbose { log("open: \(tiles.count) tiles, starting on \(selected + 1)") }
        isOpen = true
        panel.present(tiles: tiles, selected: selected, desktopSelection: desktopSelection)
        loadThumbnails()
    }

    /// Thumbnails are captured off the main thread and dropped in as they arrive, so the
    /// overlay appears immediately instead of waiting on the window server.
    private func loadThumbnails() {
        let snapshot = tiles
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            for tile in snapshot {
                switch tile {
                case .window(_, let window):
                    let image = Thumbnails.image(for: window, self.sky)
                    if image == nil {
                        log("capture returned nothing for \(window.appName) wid=\(window.id)"
                            + " - Screen Recording permission is the usual cause")
                    }
                    DispatchQueue.main.async {
                        guard self.isOpen else { return }
                        self.panel.switcherView.thumbnails[window.id] = image
                        self.panel.switcherView.needsDisplay = true
                    }
                case .desktop(let space, let windows):
                    let image = Thumbnails.desktopPreview(space: space, windows: windows, self.sky)
                    DispatchQueue.main.async {
                        guard self.isOpen else { return }
                        self.panel.switcherView.desktopPreviews[space.id] = image
                        self.panel.switcherView.needsDisplay = true
                    }
                }
            }
        }
    }

    func advance(by step: Int) {
        guard isOpen, !tiles.isEmpty else { return }
        selected = (selected + step + tiles.count) % tiles.count
        if verbose { log("advance \(step > 0 ? "forward" : "back") -> tile \(selected + 1)/\(tiles.count)") }
        panel.refresh(selected: selected, desktopSelection: desktopSelection)
    }

    /// Arrow keys only do anything on a desktop tile, where they pick which of that desktop's
    /// windows will be focused, and they stop at the ends rather than spilling into the next
    /// tile.
    func moveWithinDesktop(by step: Int) {
        guard isOpen, selected < tiles.count,
              case .desktop(let space, let windows) = tiles[selected],
              windows.count > 1
        else { return }
        let current = desktopSelection[space.id] ?? 0
        desktopSelection[space.id] = min(max(current + step, 0), windows.count - 1)
        if verbose { log("desktop arrow -> window \(desktopSelection[space.id]! + 1)/\(windows.count)") }
        panel.refresh(selected: selected, desktopSelection: desktopSelection)
    }

    /// Jumps straight to the tile with the given number, as printed under its icon. The
    /// selection still commits on releasing Command, so a mistyped number can be corrected
    /// with another number, Tab, or Escape.
    func select(position: Int) {
        guard isOpen, tiles.indices.contains(position) else { return }
        selected = position
        if verbose { log("number key -> tile \(position + 1)/\(tiles.count)") }
        panel.refresh(selected: selected, desktopSelection: desktopSelection)
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

        guard selected < tiles.count else { return }
        let tile = tiles[selected]
        guard let window = panel.switcherView.currentWindow() else { return }
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


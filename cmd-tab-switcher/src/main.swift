import Cocoa

func log(_ message: String) {
    FileHandle.standardError.write("cmd-tab-switcher: \(message)\n".data(using: .utf8)!)
}

let tabKeyCode: Int64 = 48
let escKeyCode: Int64 = 53
let leftArrowKeyCode: Int64 = 123
let rightArrowKeyCode: Int64 = 124

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
        WindowActions.activate(window: window, space: tile.space, sky)
    }
}

// MARK: - Entry point

guard let sky = SkyLight() else {
    log("could not resolve SkyLight symbols - macOS may have changed them")
    exit(1)
}

// `--dump` prints the switcher row without showing any UI, for checking that Spaces are
// ordered and grouped the way the window server sees them.
if CommandLine.arguments.contains("--dump") {
    let tiles = WindowLister.buildTiles(sky)
    let active = sky.activeSpace
    print("active space: \(active)")
    print("tiles (\(tiles.count)), left to right:\n")
    for (index, tile) in tiles.enumerated() {
        let marker = tile.space.id == active ? " <- current" : ""
        switch tile {
        case .window(let space, let window):
            print("  \(index + 1). [fullscreen] space=\(space.id) \(window.appName)\(marker)")
            print("        \"\(window.title)\"")
        case .desktop(let space, let windows):
            print("  \(index + 1). [desktop]    space=\(space.id) \(windows.count) window(s)\(marker)")
            for window in windows {
                print("        \(window.appName)\(window.isMinimized ? " (minimized)" : "") - \"\(window.title)\"")
            }
        }
    }
    exit(0)
}

// `--capture-probe <dir>` writes each tile's captured image to disk, to tell a failed capture
// apart from one that silently comes back blank.
if let index = CommandLine.arguments.firstIndex(of: "--capture-probe") {
    let dir = index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : "/tmp"
    for tile in WindowLister.buildTiles(sky) {
        guard case .window(_, let window) = tile else { continue }
        guard let cgImage = sky.capture(windowID: window.id) else {
            print("\(window.appName) wid=\(window.id): capture returned nil")
            continue
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        let path = "\(dir)/probe_\(window.id).png"
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("\(window.appName) wid=\(window.id): \(cgImage.width)x\(cgImage.height) -> \(path)")
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Without Screen Recording the window server still answers capture requests, but hands back
// blank images rather than failing, so the tiles would silently render empty. Say so once.
// Asking is deliberately limited to a single attempt per launch: the agent is kept alive by
// launchd, so prompting on a loop is what turned one missing grant into a dialog every few
// seconds. Thumbnails are optional, so this never blocks startup.
if !CGPreflightScreenCaptureAccess() {
    log("no Screen Recording permission - tiles will render blank until it is granted in")
    log("System Settings > Privacy & Security > Screen Recording.")
    CGRequestScreenCaptureAccess()
}

/// Held statically because the event tap callback is a C function pointer and cannot capture
/// surrounding context.
enum Runtime {
    static var controller: SwitcherController!
}
Runtime.controller = SwitcherController(sky: sky)

// `--show N` displays the overlay for N seconds without binding any key, to check appearance.
if let index = CommandLine.arguments.firstIndex(of: "--show") {
    let seconds = index + 1 < CommandLine.arguments.count
        ? (Double(CommandLine.arguments[index + 1]) ?? 3.0) : 3.0
    Runtime.controller.open(backwards: false)
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
    app.run()
}

let mask: CGEventMask =
    (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

func makeEventTap() -> CFMachPort? {
    CGEvent.tapCreate(
    tap: .cghidEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: mask,
    callback: { _, type, event, _ in
        let controller = Runtime.controller!
        let code = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .flagsChanged {
            // Letting go of Command is what commits the selection, exactly like the real
            // Cmd+Tab. This has to be checked on every flags change, not just Command's own
            // key code, so a chorded release still lands.
            if controller.isOpen && !event.flags.contains(.maskCommand) {
                DispatchQueue.main.async { controller.commit() }
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        if code == tabKeyCode && event.flags.contains(.maskCommand) {
            let backwards = event.flags.contains(.maskShift)
            DispatchQueue.main.async {
                if controller.isOpen {
                    controller.advance(by: backwards ? -1 : 1)
                } else {
                    controller.open(backwards: backwards)
                }
            }
            return nil
        }

        guard controller.isOpen else { return Unmanaged.passUnretained(event) }

        switch code {
        case escKeyCode:
            DispatchQueue.main.async { controller.cancel() }
            return nil
        case leftArrowKeyCode:
            DispatchQueue.main.async { controller.moveWithinDesktop(by: -1) }
            return nil
        case rightArrowKeyCode:
            DispatchQueue.main.async { controller.moveWithinDesktop(by: 1) }
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    },
    userInfo: nil
    )
}

/// Waits for the permissions we need rather than exiting without them.
///
/// Exiting was the bug behind the permission-dialog spam: launchd keeps this agent alive, so
/// every exit meant a relaunch a few seconds later, and every relaunch asked again. Staying up
/// and re-checking quietly means the dialog appears once, and granting it takes effect on its
/// own without anything having to be restarted by hand.
var askedForAccessibility = false
var reportedTapFailure = false

func startWhenPermitted() {
    guard AXIsProcessTrusted() else {
        if !askedForAccessibility {
            askedForAccessibility = true
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            log("waiting for Accessibility permission (System Settings > Privacy & Security)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { startWhenPermitted() }
        return
    }

    guard let tap = makeEventTap() else {
        if !reportedTapFailure {
            reportedTapFailure = true
            log("waiting for Input Monitoring permission (System Settings > Privacy & Security)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { startWhenPermitted() }
        return
    }

    CFRunLoopAddSource(CFRunLoopGetCurrent(),
                       CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0),
                       .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    log("running (pid \(ProcessInfo.processInfo.processIdentifier))")
}

startWhenPermitted()
app.run()

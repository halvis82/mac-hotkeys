import Cocoa

enum Thumbnails {
    static func image(for window: WindowInfo, _ sky: SkyLight) -> NSImage? {
        guard let cgImage = sky.capture(windowID: window.id) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// The Dock owns one wallpaper window per Space, named after that Space's uuid, which is
    /// how a desktop Space gets a backdrop to preview even when it isn't the active one.
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

    /// A desktop Space has no single window to photograph, so its preview is built by hand:
    /// the Space's wallpaper with that Space's windows composited on top at their real
    /// positions, which is what makes the tile actually look like that desktop.
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

        // Back to front, so overlapping windows stack the way they do on screen.
        for window in windows.reversed() where !window.isMinimized {
            guard let capture = sky.capture(windowID: window.id) else { continue }
            // CGWindowList bounds are top-left origin; AppKit drawing is bottom-left.
            let rect = NSRect(x: window.bounds.origin.x,
                              y: canvas.height - window.bounds.origin.y - window.bounds.height,
                              width: window.bounds.width,
                              height: window.bounds.height)
            NSImage(cgImage: capture, size: rect.size).draw(in: rect)
        }

        return result
    }
}

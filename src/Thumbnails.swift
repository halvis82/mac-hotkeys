import Cocoa

enum Thumbnails {
    private static let askLock = NSLock()
    private static var askedForScreenRecording = false

    /// Asked for only when a thumbnail is actually wanted, never at startup.
    ///
    /// Only the Cmd+Tab previews need to read the screen. Requesting it when the agent launches
    /// meant using the moon key, which has nothing to do with the screen, still put up a screen
    /// recording prompt. Limited to one attempt per launch, because launchd keeps this agent
    /// alive and prompting on a loop turns one missing grant into a dialog every few seconds.
    /// Locked because thumbnails are captured on several threads at once.
    static func ensureScreenRecordingRequested() {
        askLock.lock()
        defer { askLock.unlock() }
        guard !askedForScreenRecording else { return }
        askedForScreenRecording = true
        guard !CGPreflightScreenCaptureAccess() else { return }
        log("no Screen Recording permission - switcher tiles will render blank until granted")
        CGRequestScreenCaptureAccess()
    }

    /// How many pixels an image of `size` needs so that, drawn aspect-fill into a tile of
    /// `cover` pixels, no detail is lost. Never more than it already has.
    static func scaledPixelSize(of size: CGSize, toCover cover: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, cover.width > 0, cover.height > 0 else { return size }
        let scale = min(1, max(cover.width / size.width, cover.height / size.height))
        return CGSize(width: max(1, (size.width * scale).rounded(.up)),
                      height: max(1, (size.height * scale).rounded(.up)))
    }

    /// An RGBA bitmap to draw into, in the captures' own color space where that is possible.
    ///
    /// Captures come back in the display's space, which is wider than sRGB on these screens.
    /// Converting through sRGB would clip saturated colors, so sRGB is only the fallback for a
    /// space a bitmap context cannot be made in.
    private static func bitmapContext(pixels: CGSize, preferring space: CGColorSpace?) -> CGContext? {
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let candidates = [space, CGColorSpace(name: CGColorSpace.sRGB)].compactMap { $0 }
        for candidate in candidates where candidate.model == .rgb {
            if let context = CGContext(data: nil,
                                       width: Int(pixels.width),
                                       height: Int(pixels.height),
                                       bitsPerComponent: 8,
                                       bytesPerRow: 0,
                                       space: candidate,
                                       bitmapInfo: info) {
                return context
            }
        }
        return nil
    }

    /// Resamples a capture down to what the tile will show.
    ///
    /// Captures come back at full window size, 1512 points wide for a fullscreen window, and the
    /// tile they go in is a fifth of that. Drawing them scaled on every redraw made each Tab press
    /// resample every thumbnail again on the main thread, which measured 8ms typically and up to
    /// 50ms, time during which the next keystroke waits. Scaling once, here, off the main thread,
    /// makes the redraw nearly free.
    static func downscaled(_ image: CGImage, toCover cover: CGSize) -> CGImage {
        let source = CGSize(width: image.width, height: image.height)
        let target = scaledPixelSize(of: source, toCover: cover)
        guard target.width < source.width || target.height < source.height,
              let context = bitmapContext(pixels: target, preferring: image.colorSpace)
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: target))
        return context.makeImage() ?? image
    }

    /// A window's thumbnail, sized for a tile of `cover` pixels.
    ///
    /// The NSImage keeps the window's own size in points, so the tile's aspect-fill math sees
    /// exactly what it always did. Only the pixels behind it are fewer.
    static func image(for window: WindowInfo, _ sky: SkyLight, cover: CGSize) -> NSImage? {
        ensureScreenRecordingRequested()
        guard let cgImage = sky.capture(windowID: window.id) else { return nil }
        let size = NSSize(width: cgImage.width, height: cgImage.height)
        return NSImage(cgImage: downscaled(cgImage, toCover: cover), size: size)
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
    ///
    /// `canvas` is the screen size in points and `cover` the tile's size in pixels. The preview
    /// used to be painted at full Retina resolution, 3024x1964 for a tile of 600x380, one
    /// capture after another, and took over 100ms to arrive. It is now painted at the size the
    /// tile shows it, with every capture taken at once.
    static func desktopPreview(space: SpaceInfo,
                               windows: [WindowInfo],
                               _ sky: SkyLight,
                               canvas: CGSize,
                               cover: CGSize) -> NSImage? {
        ensureScreenRecordingRequested()
        guard canvas.width > 0, canvas.height > 0 else { return nil }

        // Slot 0 is the wallpaper, then the windows in the order given.
        let visible = windows.filter { !$0.isMinimized }
        var ids: [CGWindowID?] = [wallpaperWindowID(forSpaceUUID: space.uuid)]
        ids.append(contentsOf: visible.map { $0.id })
        var captures = [CGImage?](repeating: nil, count: ids.count)
        captures.withUnsafeMutableBufferPointer { slots in
            let slots = slots
            DispatchQueue.concurrentPerform(iterations: ids.count) { index in
                if let id = ids[index] { slots[index] = sky.capture(windowID: id) }
            }
        }

        let pixels = scaledPixelSize(of: canvas, toCover: cover)
        let space = captures.lazy.compactMap { $0?.colorSpace }.first
        guard let context = bitmapContext(pixels: pixels, preferring: space) else { return nil }
        context.interpolationQuality = .high
        // Drawn in points from here on, the same coordinates the full-size version used.
        context.scaleBy(x: pixels.width / canvas.width, y: pixels.height / canvas.height)

        if let wallpaper = captures[0] {
            context.draw(wallpaper, in: CGRect(origin: .zero, size: canvas))
        } else {
            context.setFillColor(NSColor.darkGray.cgColor)
            context.fill(CGRect(origin: .zero, size: canvas))
        }

        // Back to front, so overlapping windows stack the way they do on screen.
        for (index, window) in visible.enumerated().reversed() {
            guard let capture = captures[index + 1] else { continue }
            // CGWindowList bounds are top-left origin; Core Graphics drawing is bottom-left.
            let rect = CGRect(x: window.bounds.origin.x,
                              y: canvas.height - window.bounds.origin.y - window.bounds.height,
                              width: window.bounds.width,
                              height: window.bounds.height)
            context.draw(capture, in: rect)
        }

        guard let composed = context.makeImage() else { return nil }
        return NSImage(cgImage: composed, size: canvas)
    }
}

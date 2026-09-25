import Cocoa

// Tests against the real window server, AX and screen. They need the same Accessibility and
// Screen Recording grants as the agent (the terminal running them is what gets asked), and they
// read whatever windows happen to be open, so they only ever compare two ways of computing the
// same thing, or check properties that must hold for any set of windows.

/// Everything about a listed window that anything downstream reads.
private func fingerprint(_ bySpace: [UInt64?: [WindowInfo]]) -> [String] {
    bySpace.flatMap { space, windows in
        windows.enumerated().map { index, w in
            "\(space.map(String.init) ?? "nil")#\(index) \(w.id) pid=\(w.pid) \(w.appName) key=\(w.appKey) "
                + "title=\(w.title) bounds=\(w.bounds) min=\(w.isMinimized)"
        }
    }.sorted()
}

private func fingerprint(_ tiles: [Tile]) -> [String] {
    tiles.map { tile in
        "\(tile.space.id)/\(tile.space.isFullscreen) " + tile.windows.map { "\($0.id):\($0.appKey):\($0.title)" }.joined(separator: "|")
    }
}

/// Runs `a` and `b` until they agree, since windows can change between the two calls. Returns
/// the last pair when they never do.
private func agree<T: Equatable>(attempts: Int = 6, _ a: () -> T, _ b: () -> T) -> (T, T, Bool) {
    var last: (T, T) = (a(), b())
    for _ in 0..<attempts {
        if last.0 == last.1 { return (last.0, last.1, true) }
        usleep(150_000)
        last = (a(), b())
    }
    return (last.0, last.1, last.0 == last.1)
}

/// Draws an image the way a tile does (aspect fill into 300x190 points at 2x) and returns RGBA.
private func renderedAsTile(_ image: NSImage) -> [UInt8] {
    let width = 600, height = 380
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let rect = NSRect(x: 0, y: 0, width: width, height: height)
    let scale = max(rect.width / image.size.width, rect.height / image.size.height)
    let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                          width: size.width, height: size.height),
               from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return Array(UnsafeBufferPointer(start: rep.bitmapData!, count: width * height * 4))
}

/// Mean absolute difference per color channel, 0 to 255.
private func meanDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
    var total = 0
    var count = 0
    for index in stride(from: 0, to: min(a.count, b.count), by: 4) {
        for channel in 0..<3 { total += abs(Int(a[index + channel]) - Int(b[index + channel])); count += 1 }
    }
    return Double(total) / Double(max(count, 1))
}

/// Mean brightness of a strip across the middle of the main display, where the switcher sits.
private typealias CreateImageFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
private func screenStripBrightness() -> Double {
    // Resolved at runtime: the SDK marks it unavailable in favor of ScreenCaptureKit, which is
    // asynchronous and far heavier than a test needs.
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return -1 }
    let createImage = unsafeBitCast(symbol, to: CreateImageFn.self)
    let bounds = CGDisplayBounds(CGMainDisplayID())
    let strip = CGRect(x: bounds.midX - 300, y: bounds.midY - 40, width: 600, height: 80)
    guard let image = createImage(strip, CGWindowListOption.optionOnScreenOnly.rawValue, kCGNullWindowID,
                                  CGWindowImageOption.nominalResolution.rawValue)?.takeRetainedValue(),
          let context = CGContext(data: nil, width: 60, height: 8, bitsPerComponent: 8, bytesPerRow: 240,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return -1 }
    context.draw(image, in: CGRect(x: 0, y: 0, width: 60, height: 8))
    let pixels = context.data!.bindMemory(to: UInt8.self, capacity: 60 * 8 * 4)
    var total = 0.0
    for index in 0..<(60 * 8) { total += Double(pixels[index * 4]) + Double(pixels[index * 4 + 1]) + Double(pixels[index * 4 + 2]) }
    return total / Double(60 * 8 * 3)
}

func liveTests(_ sky: SkyLight) {
    suite("Live: permissions") {
        test("Accessibility is granted to whatever runs the tests") {
            expect(AXIsProcessTrusted(), "grant Accessibility to this terminal, or the AX paths are untested")
        }
    }

    suite("Live: the fast window listing gives the old answers") {
        test("every window, Space, title and minimized flag matches the old algorithm") {
            for _ in 0..<5 {
                let (new, old, same) = agree({ fingerprint(WindowLister.allWindows(sky)) },
                                             { fingerprint(Reference.allWindows(sky)) })
                if !same {
                    fail("differs:\n        new only: \(Set(new).subtracting(old))\n        old only: \(Set(old).subtracting(new))")
                    return
                }
            }
        }

        test("the switcher row matches the old algorithm, with and without history") {
            let recency: (CGWindowID) -> Int = { Int($0 % 7) }
            for rank in [{ (_: CGWindowID) in Int.max }, recency] {
                let (new, old, same) = agree({ fingerprint(WindowLister.buildTiles(sky, recency: rank, preferKeyWindows: false)) },
                                             { fingerprint(Reference.buildTiles(sky, recency: rank)) })
                expect(same, "new \(new)\n        old \(old)")
            }
        }

        test("Cmd+` sees the same windows as before for every app with windows") {
            let pids = Set(WindowLister.allWindows(sky).values.flatMap { $0.map(\.pid) })
            expect(!pids.isEmpty, "no windows at all, which makes this test meaningless")
            for pid in pids {
                let (new, old, same) = agree({ WindowLister.switchableWindows(ofPID: pid, sky).map(\.id) },
                                             { Reference.switchableWindows(ofPID: pid, sky).map(\.id) })
                expect(same, "pid \(pid): new \(new) old \(old)")
            }
        }

        test("asking each Space for its windows agrees with asking each window for its Space") {
            let ids = Reference.allWindows(sky).values.flatMap { $0.map(\.id) }
            guard let membership = sky.spaces(ofWindowsOn: sky.orderedSpaces().map(\.id)) else {
                print("      (not available on this macOS, the per-window route is used)")
                return
            }
            // Every ordinary window, the hidden ones included, since "on no Space" is exactly
            // what decides whether an app's helper window is kept out of the switcher.
            let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let layerZero = all.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
                .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
            expect(!ids.isEmpty && !layerZero.isEmpty)
            for id in layerZero {
                let perWindow = sky.space(ofWindow: id)
                switch membership[id] {
                case nil: expect(perWindow == nil, "window \(id) is on no Space's list but on space \(perWindow ?? 0)")
                case let spaces? where spaces.count == 1: expectEqual(spaces[0], perWindow ?? 0, "window \(id)")
                default: break // on several Spaces: asked about directly, so nothing to compare
                }
            }
        }

        test("asking every app in parallel agrees with asking them one at a time") {
            let pids = Set(WindowLister.allWindows(sky).values.flatMap { $0.map(\.pid) })
            for _ in 0..<5 {
                let parallel = WindowLister.axWindowFacts(standardFor: pids, minimizedFor: pids)
                for pid in pids {
                    let (p, s, same) = agree({ parallel[pid].map { [$0.standard, $0.minimized] } ?? [] },
                                             { [Reference.axStandardWindowIDs(ofPID: pid), Reference.minimizedWindowIDs(ofPID: pid)] })
                    expect(same, "pid \(pid): parallel \(p) serial \(s)")
                }
            }
        }
    }

    suite("Live: row invariants") {
        let tiles = WindowLister.buildTiles(sky)
        let spaces = sky.orderedSpaces()

        test("there is at least one tile") { expect(!tiles.isEmpty) }

        test("no window appears twice") {
            let ids = tiles.flatMap { $0.windows.map(\.id) }
            expectEqual(ids.count, Set(ids).count)
        }

        test("each desktop tile shows each app by its key window, where that is on the desktop") {
            for case .desktop(let space, let windows) in tiles {
                let listed = WindowLister.allWindows(sky)[space.id] ?? []
                for window in windows {
                    guard let key = WindowActions.focusedWindowID(ofPID: window.pid),
                          listed.contains(where: { $0.id == key && $0.appKey == window.appKey })
                    else { continue }
                    expectEqual(window.id, key, "\(window.appName) on space \(space.id)")
                }
            }
        }

        test("each desktop tile shows each app once") {
            for case .desktop(let space, let windows) in tiles {
                expectEqual(windows.count, Set(windows.map(\.appKey)).count, "space \(space.id)")
            }
        }

        test("tile kinds match their Space kinds, and tiles follow Space order") {
            let order = Dictionary(uniqueKeysWithValues: spaces.enumerated().map { ($1.id, $0) })
            var last = -1
            for tile in tiles {
                expect(tile.isDesktop == !tile.space.isFullscreen, "tile on space \(tile.space.id)")
                guard let position = order[tile.space.id] else { fail("space \(tile.space.id) unknown"); continue }
                expect(position >= last, "space \(tile.space.id) out of order")
                last = position
            }
        }

        test("only desktop tiles hold minimized windows") {
            for case .window(_, let window) in tiles { expect(!window.isMinimized) }
        }
    }

    suite("Live: thumbnails") {
        let tiles = WindowLister.buildTiles(sky)
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let canvas = screen.frame.size
        let cover = CGSize(width: 300 * screen.backingScaleFactor, height: 190 * screen.backingScaleFactor)

        test("captures taken in parallel match captures taken one at a time") {
            let ids = tiles.flatMap { $0.windows.filter { !$0.isMinimized }.map(\.id) }
            let serial = ids.map { sky.capture(windowID: $0).map { "\($0.width)x\($0.height)" } ?? "nil" }
            for _ in 0..<10 {
                var parallel = [String](repeating: "", count: ids.count)
                parallel.withUnsafeMutableBufferPointer { slots in
                    let slots = slots
                    DispatchQueue.concurrentPerform(iterations: ids.count) { index in
                        slots[index] = sky.capture(windowID: ids[index]).map { "\($0.width)x\($0.height)" } ?? "nil"
                    }
                }
                expectEqual(parallel, serial)
            }
        }

        test("window thumbnails look the same in a tile as the full-size captures did") {
            for case .window(_, let window) in tiles {
                guard let old = Reference.image(for: window, sky),
                      let new = Thumbnails.image(for: window, sky, cover: cover)
                else { fail("no capture for \(window.appName), is Screen Recording granted?"); continue }
                expectEqual(new.size, old.size, "the tile's geometry must not change")
                let difference = meanDifference(renderedAsTile(old), renderedAsTile(new))
                print("      \(window.appName): mean difference \(String(format: "%.2f", difference))/255")
                expect(difference < 4, "\(window.appName) differs by \(difference)/255")
            }
        }

        test("desktop previews look the same in a tile as the full-size composite did") {
            var checked = 0
            for case .desktop(let space, let windows) in tiles {
                guard let old = Reference.desktopPreview(space: space, windows: windows, sky),
                      let new = Thumbnails.desktopPreview(space: space, windows: windows, sky, canvas: canvas, cover: cover)
                else { fail("no preview for space \(space.id)"); continue }
                expectEqual(new.size, old.size, "the tile's geometry must not change")
                let difference = meanDifference(renderedAsTile(old), renderedAsTile(new))
                print("      desktop \(space.id): mean difference \(String(format: "%.2f", difference))/255")
                expect(difference < 4, "desktop \(space.id) differs by \(difference)/255")
                checked += 1
            }
            if checked == 0 { print("      (no desktop tile right now, nothing to compare)") }
        }
    }

    suite("Live: the overlay") {
        test("a fresh panel is on no Space as it is shown, which is what the agent logs as winSpace") {
            let panel = OverlayPanel()
            panel.alphaValue = 0 // shown for real, but invisible
            panel.present(tiles: WindowLister.buildTiles(sky), selected: 0, desktopSelection: [:])
            expect(panel.isVisible)
            let space = sky.space(ofWindow: CGWindowID(panel.windowNumber))
            expect(space == nil, "panel is tied to space \(space ?? 0)")
            panel.dismiss()
            expect(!panel.isVisible, "dismissing must take the panel off screen at once")
        }

        test("the panel really draws on the current Space, and is gone the moment it is dismissed") {
            // Checked on the screen itself, since the window server's own answers can't be
            // trusted for this. A panel that has been up a moment is reported on a desktop Space
            // even while it is plainly drawing over a fullscreen one. This flashes the switcher
            // for a fraction of a second.
            let before = screenStripBrightness()
            let panel = OverlayPanel()
            panel.present(tiles: WindowLister.buildTiles(sky), selected: 0, desktopSelection: [:])
            runMainLoop(for: 0.25)
            let during = screenStripBrightness()
            panel.dismiss()
            // One short run-loop turn, which is what commit() allows before a Space change. The
            // old default fade was still over 90% on screen at this point.
            runMainLoop(for: 0.02)
            let gone = screenStripBrightness()
            print(String(format: "      screen %.1f, with panel %.1f, right after dismiss %.1f", before, during, gone))
            expect(before >= 0, "could not read the screen, is Screen Recording granted?")
            expect(abs(during - before) > 0.5, "the panel did not change the screen")
            expect(abs(gone - before) < abs(during - before) / 2, "the panel was still on screen after dismiss")
        }

        test("the panel neither fades nor takes focus") {
            let panel = OverlayPanel()
            expectEqual(panel.animationBehavior, .none)
            expect(!panel.canBecomeKey && !panel.canBecomeMain)
            expect(panel.collectionBehavior.contains(.canJoinAllSpaces) && panel.collectionBehavior.contains(.fullScreenAuxiliary))
        }
    }
}

// MARK: - Timing

private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
private func p90(_ values: [Double]) -> Double { values.sorted()[Int(Double(values.count) * 0.9)] }

private func time(_ runs: Int, _ body: () -> Void) -> [Double] {
    (0..<runs).map { _ in
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        usleep(20_000)
        return elapsed
    }
}

private func report(_ label: String, old: [Double], new: [Double]) {
    print(String(format: "  %-32@ before med %6.1f p90 %6.1f max %6.1f   after med %6.1f p90 %6.1f max %6.1f  (ms)",
                 label as NSString, median(old), p90(old), old.max() ?? 0, median(new), p90(new), new.max() ?? 0))
}

func benchmarks(_ sky: SkyLight) {
    print("\nTimings, before (the frozen old code) against after, interleaved so both see the same load")
    var oldList: [Double] = [], newList: [Double] = []
    for _ in 0..<30 {
        oldList += time(1) { _ = Reference.buildTiles(sky) }
        newList += time(1) { _ = WindowLister.buildTiles(sky) }
    }
    report("building the row (on keypress)", old: oldList, new: newList)

    let tiles = WindowLister.buildTiles(sky)
    let screen = NSScreen.main ?? NSScreen.screens[0]
    let cover = CGSize(width: 300 * screen.backingScaleFactor, height: 190 * screen.backingScaleFactor)

    var oldThumbs: [Double] = [], newThumbs: [Double] = []
    for _ in 0..<6 {
        oldThumbs += time(1) {
            for tile in tiles {
                switch tile {
                case .window(_, let w): _ = Reference.image(for: w, sky)
                case .desktop(let s, let ws): _ = Reference.desktopPreview(space: s, windows: ws, sky)
                }
            }
        }
        newThumbs += time(1) {
            DispatchQueue.concurrentPerform(iterations: tiles.count) { index in
                switch tiles[index] {
                case .window(_, let w): _ = Thumbnails.image(for: w, sky, cover: cover)
                case .desktop(let s, let ws): _ = Thumbnails.desktopPreview(space: s, windows: ws, sky,
                                                                             canvas: screen.frame.size, cover: cover)
                }
            }
        }
    }
    report("all previews filled in", old: oldThumbs, new: newThumbs)

    func redrawTimes(_ fill: (SwitcherView) -> Void) -> [Double] {
        let view = SwitcherView()
        view.tiles = tiles
        let size = view.layoutSize(maxWidth: screen.frame.width - 90)
        view.frame = NSRect(origin: .zero, size: size)
        fill(view)
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        return time(60) {
            view.selected = (view.selected + 1) % max(tiles.count, 1)
            view.cacheDisplay(in: view.bounds, to: rep)
        }
    }
    let oldRedraw = redrawTimes { view in
        for tile in tiles {
            switch tile {
            case .window(_, let w): view.thumbnails[w.id] = Reference.image(for: w, sky)
            case .desktop(let s, let ws): view.desktopPreviews[s.id] = Reference.desktopPreview(space: s, windows: ws, sky)
            }
        }
    }
    let newRedraw = redrawTimes { view in
        for tile in tiles {
            switch tile {
            case .window(_, let w): view.thumbnails[w.id] = Thumbnails.image(for: w, sky, cover: cover)
            case .desktop(let s, let ws): view.desktopPreviews[s.id] = Thumbnails.desktopPreview(space: s, windows: ws, sky,
                                                                                               canvas: screen.frame.size, cover: cover)
            }
        }
    }
    report("redraw per Tab press", old: oldRedraw, new: newRedraw)
}

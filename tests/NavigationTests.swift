import Cocoa

// Drives real Space switches, so it only runs with `./test.sh --navigation`, and it moves the
// screen around for a few minutes. It needs one app with two windows on two fullscreen Spaces
// (two fullscreen Chrome windows is the case it was written for), a desktop with a window on it,
// and ideally a second app on a fullscreen Space. It ends back where it started.
//
// Every switch is checked three ways, because each one alone has lied before:
//   - the Space it ends on,
//   - the path it took there, sampled every 5ms, which must go straight from where it started
//     to where it was sent. Ending up right after a detour through another window is the bug
//     where Cmd+Tab from the desktop to Chrome window B showed window A first.
//   - the screen itself, compared against the target window's own pixels, since the window
//     server happily reports a Space as current while the screen still shows another.

private typealias CreateImageFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

private func grayscale(_ image: CGImage) -> [Double] {
    let width = 48, height = 30
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let pixels = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
    return (0..<(width * height)).map {
        (Double(pixels[$0 * 4]) + Double(pixels[$0 * 4 + 1]) + Double(pixels[$0 * 4 + 2])) / 3
    }
}

/// How far what the screen shows where the window sits is from the window's own pixels, 0 to
/// 255. Near zero means the screen really is showing that window.
func screenDifference(_ sky: SkyLight, _ window: WindowInfo) -> Double? {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
    let createImage = unsafeBitCast(symbol, to: CreateImageFn.self)
    // Where the window is now. Stage Manager shows windows outside the current stage as small
    // thumbnails and restores them to full size when they come forward, so the bounds read
    // when the row was built can be a 124x98 thumbnail of a window that is now full size.
    var bounds = window.bounds
    if let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, window.id) as? [[String: Any]])?.first,
       let dict = info[kCGWindowBounds as String] as? NSDictionary {
        CGRectMakeWithDictionaryRepresentation(dict as CFDictionary, &bounds)
    }
    guard let shot = createImage(bounds, CGWindowListOption.optionOnScreenOnly.rawValue, kCGNullWindowID,
                                 CGWindowImageOption.nominalResolution.rawValue)?.takeRetainedValue(),
          let own = sky.capture(windowID: window.id)
    else { return nil }
    let a = grayscale(shot), b = grayscale(own)
    guard !a.isEmpty, a.count == b.count else { return nil }
    return zip(a, b).map { abs($0 - $1) }.reduce(0, +) / Double(a.count)
}

/// Every distinct active Space from now until it has been still for 0.7s, with when it began.
private func traceSpaces(_ sky: SkyLight, _ done: @escaping ([(at: TimeInterval, space: UInt64)]) -> Void) {
    let start = Date()
    var trace: [(at: TimeInterval, space: UInt64)] = [(0, sky.activeSpace)]
    var quietSince = Date()
    func poll() {
        let now = sky.activeSpace
        if now != trace.last!.space {
            trace.append((Date().timeIntervalSince(start), now))
            quietSince = Date()
        }
        if Date().timeIntervalSince(quietSince) > 0.7 { done(trace); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.005, execute: poll)
    }
    poll()
}

private struct Stop {
    let name: String
    let window: WindowInfo
    let space: SpaceInfo
}

private struct Hop {
    let from: UInt64
    let to: Stop
    let path: [(at: TimeInterval, space: UInt64)]
    let focused: CGWindowID?
    let difference: Double?
}

/// Sends the switcher to `stop` the way a commit does and reports what really happened.
private func hop(_ sky: SkyLight, to stop: Stop) -> Hop? {
    var result: Hop?
    let from = sky.activeSpace
    WindowActions.activate(window: stop.window, space: stop.space, sky)
    traceSpaces(sky) { path in
        // A moment more for the raise that follows arrival on a desktop.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            result = Hop(from: from, to: stop, path: path, focused: WindowActions.focusedWindowID(),
                         difference: screenDifference(sky, stop.window))
        }
    }
    let deadline = Date().addingTimeInterval(8)
    while result == nil, Date() < deadline { runMainLoop(for: 0.02) }
    return result
}

private func check(_ hop: Hop?, _ sky: SkyLight) {
    if screenIsLocked {
        print("\n❌ the screen locked during the run, so the rest of it means nothing. Unlock and run again.")
        exit(1)
    }
    guard let hop = hop else { fail("never settled"); return }
    let path = hop.path.map { "\($0.space)@\(Int($0.at * 1000))ms" }.joined(separator: " -> ")
    print("      path \(path), screen difference \(hop.difference.map { String(format: "%.1f", $0) } ?? "?")")
    expectEqual(hop.path.last?.space, hop.to.space.id, "ended on the wrong Space")
    let detours = hop.path.map(\.space).filter { $0 != hop.from && $0 != hop.to.space.id }
    expect(detours.isEmpty, "went by Space \(detours) on the way: \(path)")
    expect(hop.path.count <= 2, "did not go straight there: \(path)")
    if !hop.to.window.isMinimized {
        expectEqual(hop.focused, hop.to.window.id, "the wrong window has focus")
        if let difference = hop.difference {
            expect(difference < 12, String(format: "the screen does not show the window (difference %.1f)", difference))
        } else {
            fail("could not compare the screen, is Screen Recording granted?")
        }
    }
}

func navigationTests(_ sky: SkyLight) {
    let tiles = WindowLister.buildTiles(sky)
    var fullscreenByApp: [String: [Stop]] = [:]
    for case .window(let space, let window) in tiles {
        fullscreenByApp[window.appKey, default: []].append(
            Stop(name: "\(window.appName) \"\(window.title.prefix(24))\"", window: window, space: space))
    }
    guard let pair = fullscreenByApp.values.first(where: { $0.count >= 2 }),
          let desktopTile = tiles.first(where: { $0.isDesktop }),
          let desktopWindow = desktopTile.windows.first(where: { !$0.isMinimized })
    else {
        print("\nNavigation\n  ⚠️ skipped: needs one app with two fullscreen windows, and a desktop with a window on it")
        return
    }
    let startSpace = sky.activeSpace
    let a = pair.first { $0.space.id == startSpace } ?? pair[0]
    let b = pair.first { $0.window.id != a.window.id }!
    let desktop = Stop(name: "desktop \(desktopWindow.appName)", window: desktopWindow, space: desktopTile.space)
    let other = fullscreenByApp.values.first { $0[0].window.appKey != a.window.appKey }?.first

    // Each scenario: where to stand first, then the switch being tested.
    var scenarios: [(String, [Stop])] = [
        ("desktop to the app's other window (the reported bug)", [a, desktop, b]),
        ("desktop to the app's other window, the other way", [b, desktop, a]),
        ("desktop to the app's most recent window", [a, desktop, a]),
        ("between two windows of the same app", [a, b]),
        ("between two windows of the same app, back", [b, a]),
        ("fullscreen to the desktop", [a, desktop]),
    ]
    if let other = other {
        scenarios += [
            ("from another app's fullscreen Space to the app's other window", [a, other, b]),
            ("from another app's fullscreen Space to the app's recent window", [a, other, a]),
            ("to another app's fullscreen Space", [a, other]),
            ("another app's fullscreen Space to the desktop", [other, desktop]),
        ]
    }

    suite("Navigation (moves the screen)") {
        for (name, stops) in scenarios {
            for round in 1...3 {
                for stop in stops.dropLast() { _ = hop(sky, to: stop) }
                let result = hop(sky, to: stops.last!)
                test("\(name), round \(round)") { check(result, sky) }
            }
        }

        // A long random tour, checking every single hop. Entering a fullscreen Space the wrong
        // way leaves it half-entered and poisons every switch after it, so this is where that
        // would surface: not on the first hop, but a few later.
        var stops = [a, b, desktop]
        if let other = other { stops.append(other) }
        var generator = SystemRandomNumberGenerator()
        var previous = sky.activeSpace
        var failures = 0
        for step in 1...30 {
            var next = stops.randomElement(using: &generator)!
            while next.space.id == previous { next = stops.randomElement(using: &generator)! }
            let result = hop(sky, to: next)
            previous = next.space.id
            let before = TestRun.failed
            test("random tour hop \(step): to \(next.name)") { check(result, sky) }
            if TestRun.failed > before { failures += 1 }
        }
        expect(failures == 0)

        _ = hop(sky, to: a) // home again
    }
}

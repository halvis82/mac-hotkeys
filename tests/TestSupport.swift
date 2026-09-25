import Cocoa

// A deliberately tiny test harness. The project is built with plain swiftc rather than a Swift
// package, so XCTest would mean restructuring the build for no gain. `test.sh` compiles these
// files together with everything in src/ except main.swift, and runs the result.

enum TestRun {
    static var passed = 0
    static var failed = 0
    static var failures: [String] = []
    static var currentTest = ""
    static var currentFailed = false
}

func suite(_ name: String, _ body: () -> Void) {
    print("\n\(name)")
    body()
}

func test(_ name: String, _ body: () throws -> Void) {
    TestRun.currentTest = name
    TestRun.currentFailed = false
    do {
        try body()
    } catch {
        fail("threw \(error)")
    }
    if TestRun.currentFailed {
        TestRun.failed += 1
        print("  ❌ \(name)")
    } else {
        TestRun.passed += 1
        print("  ✅ \(name)")
    }
}

func fail(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
    TestRun.currentFailed = true
    let text = "\(TestRun.currentTest): \(message) (\(file):\(line))"
    TestRun.failures.append(text)
    print("      \(message) (\(file):\(line))")
}

func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "expectation failed",
            file: StaticString = #fileID, line: UInt = #line) {
    if !condition() { fail(message(), file: file, line: line) }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "",
                               file: StaticString = #fileID, line: UInt = #line) {
    if actual != expected {
        fail("expected \(expected), got \(actual)\(message.isEmpty ? "" : " - \(message)")", file: file, line: line)
    }
}

/// Spins the main run loop, for anything scheduled with asyncAfter on the main queue.
func runMainLoop(for seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

// MARK: - Fixtures

func window(_ id: CGWindowID,
            pid: pid_t = 100,
            app: String = "App",
            key: String? = nil,
            title: String = "",
            size: CGSize = CGSize(width: 800, height: 600),
            origin: CGPoint = .zero,
            minimized: Bool = false) -> WindowInfo {
    WindowInfo(id: id, pid: pid, appName: app, appKey: key ?? "com.test.\(app)", title: title,
               bounds: CGRect(origin: origin, size: size), isMinimized: minimized)
}

func desktop(_ id: UInt64) -> SpaceInfo {
    SpaceInfo(id: id, uuid: "uuid-\(id)", displayUUID: "display", isFullscreen: false)
}

func fullscreen(_ id: UInt64) -> SpaceInfo {
    SpaceInfo(id: id, uuid: "uuid-\(id)", displayUUID: "display", isFullscreen: true)
}

/// A tile described by its kind, Space and window ids, which is what most assertions care about.
func describe(_ tiles: [Tile]) -> [String] {
    tiles.map { tile in
        switch tile {
        case .window(let space, let window): return "fs\(space.id):\(window.id)"
        case .desktop(let space, let windows): return "desk\(space.id):" + windows.map { "\($0.id)" }.joined(separator: ",")
        }
    }
}

/// An MRU tracker primed with a known order, most recent first.
func tracker(_ recentFirst: [CGWindowID]) -> MRUTracker {
    let mru = MRUTracker()
    for id in recentFirst.reversed() { mru.record(id) }
    return mru
}

/// Whether the screen is locked. Anything that drives or reads the real screen is meaningless
/// then: `loginwindow` is frontmost and every switch fails, which once cost two whole runs.
var screenIsLocked: Bool {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
    return (session["CGSSessionScreenIsLocked"] as? Bool) == true
}

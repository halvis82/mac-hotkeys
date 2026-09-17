import Cocoa
import ApplicationServices

// Cmd+` that also works across fullscreen Spaces.
//
// macOS's built-in "cycle windows of the front app" skips any window that lives in its own
// fullscreen Space, which makes it useless once you fullscreen anything. This replaces it:
// it finds every window of the frontmost app, figures out which Space each one is on, switches
// to that Space if needed, and raises the window.
//
// Space switching has no public API, so this uses SkyLight private symbols (resolved at runtime
// via dlsym so a missing symbol degrades to "do nothing" instead of failing to launch).

private let graveKeyCode: Int64 = 50 // the ` key

private func log(_ message: String) {
    FileHandle.standardError.write("fullscreen-cycle: \(message)\n".data(using: .utf8)!)
}

// MARK: - SkyLight private API

private typealias MainConnectionIDFn = @convention(c) () -> Int32
private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
private typealias ManagedDisplaySetCurrentSpaceFn = @convention(c) (Int32, CFString, UInt64) -> Void
private typealias GetActiveSpaceFn = @convention(c) (Int32) -> UInt64
private typealias AXUIElementGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

private struct SkyLight {
    let connectionID: Int32
    let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn
    let copySpacesForWindows: CopySpacesForWindowsFn
    let setCurrentSpace: ManagedDisplaySetCurrentSpaceFn
    let activeSpace: GetActiveSpaceFn

    init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let mainID = dlsym(handle, "SLSMainConnectionID"),
              let spaces = dlsym(handle, "SLSCopyManagedDisplaySpaces"),
              let winSpaces = dlsym(handle, "SLSCopySpacesForWindows"),
              let setSpace = dlsym(handle, "SLSManagedDisplaySetCurrentSpace"),
              let active = dlsym(handle, "SLSGetActiveSpace")
        else { return nil }
        connectionID = unsafeBitCast(mainID, to: MainConnectionIDFn.self)()
        copyManagedDisplaySpaces = unsafeBitCast(spaces, to: CopyManagedDisplaySpacesFn.self)
        copySpacesForWindows = unsafeBitCast(winSpaces, to: CopySpacesForWindowsFn.self)
        setCurrentSpace = unsafeBitCast(setSpace, to: ManagedDisplaySetCurrentSpaceFn.self)
        activeSpace = unsafeBitCast(active, to: GetActiveSpaceFn.self)
    }

    /// The Space a window lives on, or nil for windows the window server doesn't place
    /// (helper/offscreen windows, which are exactly the ones we want to skip).
    func space(ofWindow id: CGWindowID) -> UInt64? {
        guard let result = copySpacesForWindows(connectionID, 0x7, [id] as CFArray) else { return nil }
        let spaces = result.takeRetainedValue() as? [NSNumber] ?? []
        return spaces.first?.uint64Value
    }

    /// Display UUID that owns a given Space, needed to switch to it.
    func display(forSpace target: UInt64) -> String? {
        guard let result = copyManagedDisplaySpaces(connectionID) else { return nil }
        let displays = result.takeRetainedValue() as? [[String: Any]] ?? []
        for display in displays {
            let spaces = display["Spaces"] as? [[String: Any]] ?? []
            for space in spaces where (space["ManagedSpaceID"] as? NSNumber)?.uint64Value == target {
                return display["Display Identifier"] as? String
            }
        }
        return nil
    }

    func switchTo(space: UInt64) {
        guard let displayUUID = display(forSpace: space) else {
            log("no display owns space \(space)")
            return
        }
        setCurrentSpace(connectionID, displayUUID as CFString, space)
    }
}

private let axGetWindow: AXUIElementGetWindowFn? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow")
    .map { unsafeBitCast($0, to: AXUIElementGetWindowFn.self) }

// MARK: - Window model

private struct AppWindow {
    let id: CGWindowID
    let space: UInt64
    let title: String
}

/// Window ids the accessibility API currently exposes for `pid` as real, raisable document
/// windows. This only ever covers windows on the *current* Space: AX reports an empty or
/// partial window list for windows sitting on other Spaces, even when the app is frontmost.
private func axStandardWindowIDs(ofPID pid: pid_t) -> Set<CGWindowID> {
    guard let axGetWindow = axGetWindow else { return [] }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
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
        var minimized: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimized) == .success,
           (minimized as? Bool) == true { continue }
        ids.insert(id)
    }
    return ids
}

/// Every window of `pid` worth cycling to, in a stable order.
///
/// Enumeration has to come from CGWindowList, because that is the only source that sees windows
/// on other Spaces, which is the entire point of this tool. AX is then used to reject junk, but
/// only for windows on the current Space, since that is the only place AX has anything to say.
/// For windows elsewhere we fall back to a size heuristic, which is enough to drop the 1x1 and
/// sliver helper windows apps like Chrome create.
///
/// Sorted by window id so cycle order is stable from press to press. CGWindowList order shifts
/// as windows are raised, which would make the cycle jump around instead of advancing.
private func windows(forPID pid: pid_t, _ sky: SkyLight) -> [AppWindow] {
    let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }

    let activeSpace = sky.activeSpace(sky.connectionID)
    let raisable = axStandardWindowIDs(ofPID: pid)

    var result: [AppWindow] = []
    for entry in list {
        guard (entry[kCGWindowLayer as String] as? Int) == 0,
              (entry[kCGWindowOwnerPID as String] as? pid_t) == pid,
              let id = entry[kCGWindowNumber as String] as? CGWindowID,
              let space = sky.space(ofWindow: id)
        else { continue }

        if space == activeSpace {
            // AX can speak for this one, so trust it over any heuristic: it rejects both the
            // sliver windows Chrome exposes and windows that exist but cannot be raised at all
            // (Notes does this), either of which would otherwise wedge the cycle on a press
            // that appears to succeed but moves nothing.
            if !raisable.contains(id) { continue }
        } else if let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let w = bounds["Width"] as? Double, let h = bounds["Height"] as? Double,
                  w < 200 || h < 200 {
            continue
        }

        result.append(AppWindow(id: id,
                                space: space,
                                title: entry[kCGWindowName as String] as? String ?? ""))
    }
    return result.sorted { $0.id < $1.id }
}

private func focusedWindowID(ofPID pid: pid_t) -> CGWindowID? {
    guard let axGetWindow = axGetWindow else { return nil }
    let app = AXUIElementCreateApplication(pid)
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
          let element = focused
    else { return nil }
    var id: CGWindowID = 0
    guard axGetWindow(element as! AXUIElement, &id) == .success else { return nil }
    return id
}

/// Looked up by id at call time rather than held from enumeration, because for a window on
/// another Space the AX element only becomes available once that Space is current.
/// Returns false if the window isn't in the AX list yet.
@discardableResult
private func raise(windowID target: CGWindowID, ofPID pid: pid_t, verbose: Bool = false) -> Bool {
    guard let axGetWindow = axGetWindow else { return false }
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
                                               kAXWindowsAttribute as CFString, &value)
    guard status == .success, let list = value as? [AXUIElement] else { return false }
    for element in list {
        var id: CGWindowID = 0
        guard axGetWindow(element, &id) == .success, id == target else { continue }
        // All three matter: raise changes z-order, main/focused are what actually move keyboard
        // focus. Raising alone leaves kAXFocusedWindow pointing at the old window, so the next
        // press would compute the same "current" window and the cycle would never advance.
        let raised = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        let mained = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        let focused = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if verbose || raised != .success || mained != .success || focused != .success {
            log("  raise wid=\(target): raise=\(raised.rawValue) main=\(mained.rawValue) focused=\(focused.rawValue)")
        }
        return true
    }
    return false
}

/// Activates the app and raises the window, retrying until it shows up.
///
/// A window on another Space is absent from the app's AX list until that Space finishes becoming
/// current, and how long that takes depends on the Space-switch animation. Polling for it beats
/// any fixed delay, which is either too short (the raise silently does nothing and the cycle
/// never advances) or needlessly slow on every press.
private func raiseWhenAvailable(windowID target: CGWindowID,
                                ofPID pid: pid_t,
                                app: NSRunningApplication,
                                verbose: Bool,
                                deadline: Date) {
    app.activate()
    if raise(windowID: target, ofPID: pid, verbose: verbose) { return }
    guard Date() < deadline else {
        log("gave up raising wid=\(target): never appeared in the AX window list")
        return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
        raiseWhenAvailable(windowID: target, ofPID: pid, app: app, verbose: verbose, deadline: deadline)
    }
}

// MARK: - The action

private func cycleWindow(_ sky: SkyLight, dryRun: Bool, target: NSRunningApplication? = nil) {
    guard let app = target ?? NSWorkspace.shared.frontmostApplication else { return }
    let pid = app.processIdentifier
    let all = windows(forPID: pid, sky)
    guard all.count > 1 else {
        log("\(app.localizedName ?? "?") has \(all.count) cyclable window(s), nothing to switch to")
        return
    }

    let current = focusedWindowID(ofPID: pid)
    let index = all.firstIndex { $0.id == current } ?? 0
    let next = all[(index + 1) % all.count]
    let activeSpace = sky.activeSpace(sky.connectionID)

    log("\(app.localizedName ?? "?"): \(all.count) windows, current=\(current.map(String.init) ?? "?") "
        + "-> wid=\(next.id) space=\(next.space)\(next.space == activeSpace ? " (same space)" : "") "
        + "\"\(next.title)\"\(dryRun ? " [DRY RUN]" : "")")
    if dryRun { return }

    let verbose = CommandLine.arguments.contains("--verbose")
    func trace(_ what: String) {
        if verbose { log("  [\(what)] activeSpace=\(sky.activeSpace(sky.connectionID))") }
    }

    if next.space != activeSpace {
        sky.switchTo(space: next.space)
        trace("after switchTo")
    }
    raiseWhenAvailable(windowID: next.id,
                       ofPID: pid,
                       app: app,
                       verbose: verbose,
                       deadline: Date().addingTimeInterval(2.0))
    if verbose {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { trace("+1.0s") }
    }
}

// MARK: - Entry point

/// Held as statics because the event-tap callback is a C function pointer and
/// cannot capture surrounding context.
private enum Runtime {
    static var sky: SkyLight!
    static var dryRun = false
}

// Register as an accessory before touching any other AppKit API. Without this the
// process counts as a regular foreground app, so merely running --probe steals focus
// and macOS hands it to some unrelated app on exit.
NSApplication.shared.setActivationPolicy(.accessory)

Runtime.dryRun = CommandLine.arguments.contains("--dry-run")

guard let sky = SkyLight() else {
    log("could not resolve SkyLight symbols - macOS may have changed them")
    exit(1)
}
Runtime.sky = sky

/// `--pid N` targets a specific app instead of whatever is frontmost, which makes
/// `--probe` and `--cycle` usable from a terminal without that terminal being the
/// app under test.
private func targetApp() -> NSRunningApplication? {
    if let i = CommandLine.arguments.firstIndex(of: "--pid"),
       i + 1 < CommandLine.arguments.count,
       let pid = pid_t(CommandLine.arguments[i + 1]) {
        return NSRunningApplication(processIdentifier: pid)
    }
    return NSWorkspace.shared.frontmostApplication
}

// `--probe` just dumps what the tool sees, for debugging without binding any key.
// Adding --verbose also dumps every AX window with the attributes used to filter it.
if CommandLine.arguments.contains("--probe") {
    guard let app = targetApp() else { exit(1) }
    let pid = app.processIdentifier
    print("app: \(app.localizedName ?? "?") (pid \(pid))")
    print("active space: \(sky.activeSpace(sky.connectionID))")
    print("focused window: \(focusedWindowID(ofPID: pid).map(String.init) ?? "unknown")")

    if CommandLine.arguments.contains("--verbose"), let axGetWindow = axGetWindow {
        var value: CFTypeRef?
        let appElement = AXUIElementCreateApplication(pid)
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        let list = (value as? [AXUIElement]) ?? []
        print("raw AX windows (status \(status.rawValue)): \(list.count)")
        for element in list {
            var id: CGWindowID = 0
            let gotID = axGetWindow(element, &id)
            var subrole: CFTypeRef?
            let subStatus = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
            print("   wid=\(gotID == .success ? String(id) : "err\(gotID.rawValue)") "
                + "role=\(role as? String ?? "?") "
                + "subrole=\(subStatus == .success ? (subrole as? String ?? "nil") : "err\(subStatus.rawValue)") "
                + "space=\(sky.space(ofWindow: id).map(String.init) ?? "none") "
                + "\"\(titleRef as? String ?? "")\"")
        }
        print("accepted:")
    }

    for w in windows(forPID: pid, sky) { print("  wid=\(w.id) space=\(w.space) \"\(w.title)\"") }
    exit(0)
}

// `--cycle` performs exactly one cycle and exits, for testing without binding a key.
if CommandLine.arguments.contains("--cycle") {
    guard let app = targetApp() else { exit(1) }
    cycleWindow(sky, dryRun: Runtime.dryRun, target: app)
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { exit(0) }
    RunLoop.main.run()
}

guard AXIsProcessTrusted() else {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
    log("not yet trusted for Accessibility - approve it, then relaunch.")
    exit(1)
}

let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

guard let tap = CGEvent.tapCreate(
    tap: .cghidEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: mask,
    callback: { proxy, type, event, refcon in
        guard event.getIntegerValueField(.keyboardEventKeycode) == graveKeyCode,
              event.flags.contains(.maskCommand),
              !event.flags.contains(.maskControl),
              !event.flags.contains(.maskAlternate)
        else { return Unmanaged.passUnretained(event) }

        DispatchQueue.main.async { cycleWindow(Runtime.sky, dryRun: Runtime.dryRun) }
        return nil // swallow, so the app never sees the broken built-in behavior
    },
    userInfo: nil
) else {
    log("failed to create event tap - grant Input Monitoring, then relaunch.")
    exit(1)
}

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
log("running (pid \(ProcessInfo.processInfo.processIdentifier))\(Runtime.dryRun ? " [DRY RUN]" : "")")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()

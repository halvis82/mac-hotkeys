import Cocoa

// Private SkyLight bindings. Everything here is undocumented and resolved at runtime with
// dlsym, so a symbol disappearing in a future macOS surfaces as a clean startup error rather
// than a crash. See README for what each one is needed for.

typealias MainConnectionIDFn = @convention(c) () -> Int32
typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
typealias ManagedDisplaySetCurrentSpaceFn = @convention(c) (Int32, CFString, UInt64) -> Void
typealias GetActiveSpaceFn = @convention(c) (Int32) -> UInt64
typealias SpaceGetTypeFn = @convention(c) (Int32, UInt64) -> Int32
typealias HWCaptureWindowListFn = @convention(c) (Int32, UnsafeMutablePointer<UInt32>, Int32, UInt32) -> Unmanaged<CFArray>?
typealias AXUIElementGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

let axGetWindow: AXUIElementGetWindowFn? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow")
    .map { unsafeBitCast($0, to: AXUIElementGetWindowFn.self) }

/// An app's accessibility element, with a short messaging timeout.
///
/// AX calls block until the target app answers, and an app that is busy or wedged stalls the
/// caller for seconds. That matters here because the switcher queries every running app while
/// opening, on the keystroke path, so one slow app would otherwise freeze Cmd+Tab.
func appElement(pid: pid_t) -> AXUIElement {
    let element = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(element, 0.2)
    return element
}

/// A Space as the window server orders it: left to right, per display, exactly the order
/// Mission Control shows and the order the user tabs through.
struct SpaceInfo {
    let id: UInt64
    let uuid: String
    let displayUUID: String
    let isFullscreen: Bool
}

final class SkyLight {
    let connectionID: Int32
    private let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn
    private let copySpacesForWindows: CopySpacesForWindowsFn
    private let setCurrentSpace: ManagedDisplaySetCurrentSpaceFn
    private let getActiveSpace: GetActiveSpaceFn
    private let spaceGetType: SpaceGetTypeFn
    private let hwCaptureWindowList: HWCaptureWindowListFn

    init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let mainID = dlsym(handle, "SLSMainConnectionID"),
              let spaces = dlsym(handle, "SLSCopyManagedDisplaySpaces"),
              let winSpaces = dlsym(handle, "SLSCopySpacesForWindows"),
              let setSpace = dlsym(handle, "SLSManagedDisplaySetCurrentSpace"),
              let active = dlsym(handle, "SLSGetActiveSpace"),
              let type = dlsym(handle, "SLSSpaceGetType"),
              let capture = dlsym(handle, "SLSHWCaptureWindowList")
        else { return nil }
        connectionID = unsafeBitCast(mainID, to: MainConnectionIDFn.self)()
        copyManagedDisplaySpaces = unsafeBitCast(spaces, to: CopyManagedDisplaySpacesFn.self)
        copySpacesForWindows = unsafeBitCast(winSpaces, to: CopySpacesForWindowsFn.self)
        setCurrentSpace = unsafeBitCast(setSpace, to: ManagedDisplaySetCurrentSpaceFn.self)
        getActiveSpace = unsafeBitCast(active, to: GetActiveSpaceFn.self)
        spaceGetType = unsafeBitCast(type, to: SpaceGetTypeFn.self)
        hwCaptureWindowList = unsafeBitCast(capture, to: HWCaptureWindowListFn.self)
    }

    var activeSpace: UInt64 { getActiveSpace(connectionID) }

    /// All Spaces in window-server order. Space type 0 is a normal desktop, 4 is
    /// fullscreen or tiled.
    func orderedSpaces() -> [SpaceInfo] {
        guard let result = copyManagedDisplaySpaces(connectionID) else { return [] }
        let displays = result.takeRetainedValue() as? [[String: Any]] ?? []
        var out: [SpaceInfo] = []
        for display in displays {
            let displayUUID = display["Display Identifier"] as? String ?? ""
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = (space["ManagedSpaceID"] as? NSNumber)?.uint64Value else { continue }
                out.append(SpaceInfo(id: id,
                                     uuid: space["uuid"] as? String ?? "",
                                     displayUUID: displayUUID,
                                     isFullscreen: spaceGetType(connectionID, id) == 4))
            }
        }
        return out
    }

    func space(ofWindow id: CGWindowID) -> UInt64? {
        guard let result = copySpacesForWindows(connectionID, 0x7, [id] as CFArray) else { return nil }
        return (result.takeRetainedValue() as? [NSNumber])?.first?.uint64Value
    }

    func switchTo(space: SpaceInfo) {
        setCurrentSpace(connectionID, space.displayUUID as CFString, space.id)
    }

    /// Captures a window's current contents, and crucially works for windows sitting on
    /// Spaces that aren't active, which no public API can do.
    /// 0x0200 asks for nominal resolution, 0x0800 ignores the global clip shape.
    ///
    /// Returns nil when Screen Recording permission is missing for this binary, which is the
    /// usual reason thumbnails come back empty.
    func capture(windowID: CGWindowID) -> CGImage? {
        var id = windowID
        guard let result = hwCaptureWindowList(connectionID, &id, 1, 0x0200 | 0x0800) else { return nil }
        let array = result.takeRetainedValue()
        // Read the CFArray by hand. Casting it to [CGImage] compiles but silently yields an
        // empty array, because CGImage isn't a bridgeable Foundation type.
        guard CFArrayGetCount(array) > 0, let raw = CFArrayGetValueAtIndex(array, 0) else { return nil }
        // Copy it out: the image is owned by the array, which is released when this returns.
        return unsafeBitCast(raw, to: CGImage.self).copy()
    }
}

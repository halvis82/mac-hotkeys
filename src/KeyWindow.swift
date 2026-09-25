import Cocoa

/// Makes one exact window its app's key window, by id, without moving the screen.
///
/// This is what lets the switcher go straight to a window that is not its app's most recent one.
/// Activating an app heads for whichever of its windows is key, so making the chosen window key
/// first turns the Dock-style activation into a single move to exactly that window. Before this,
/// the activation went to the app's recent window and a Window-menu press redirected it
/// afterwards, which on screen was a visible stop at the wrong window on the way.
///
/// The calls are the ones AltTab and yabai use: `_SLPSSetFrontProcessWithOptions` names the
/// window, and two event records through `SLPSPostEventRecordTo` make it key. Resolved at runtime
/// and optional: if a future macOS drops them, `makeKey` returns false and the switcher falls
/// back to the redirect.
///
/// Note what these do *not* do: they never change Space. Called on their own they leave the app
/// frontmost on the Space you are on with none of its windows showing. The caller has to hand
/// focus back and then activate the app properly, which is `WindowActions.activateApp`.
enum KeyWindow {
    private typealias SetFrontProcessFn =
        @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    private typealias PostEventRecordFn =
        @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    private typealias GetProcessForPIDFn =
        @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias GetFrontProcessFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>) -> CGError

    private struct Calls {
        let setFrontProcess: SetFrontProcessFn
        let postEventRecord: PostEventRecordFn
        let getProcessForPID: GetProcessForPIDFn
        let getFrontProcess: GetFrontProcessFn
    }

    private static let calls: Calls? = {
        guard let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let front = dlsym(sky, "_SLPSSetFrontProcessWithOptions"),
              let post = dlsym(sky, "SLPSPostEventRecordTo"),
              let frontNow = dlsym(sky, "_SLPSGetFrontProcess"),
              // Deprecated and hidden from Swift, but still the only way from a pid to a PSN.
              let psn = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID")
        else {
            log("direct window focus unavailable - macOS may have changed the symbols")
            return nil
        }
        return Calls(setFrontProcess: unsafeBitCast(front, to: SetFrontProcessFn.self),
                     postEventRecord: unsafeBitCast(post, to: PostEventRecordFn.self),
                     getProcessForPID: unsafeBitCast(psn, to: GetProcessForPIDFn.self),
                     getFrontProcess: unsafeBitCast(frontNow, to: GetFrontProcessFn.self))
    }()

    static var isAvailable: Bool { calls != nil }

    /// Whether the window server itself has this app in front.
    ///
    /// Not the same as `NSRunningApplication.isActive` or `frontmostApplication`, which are
    /// AppKit's picture and trail the window server by tens of milliseconds. Going by AppKit, the
    /// hand-back below was sometimes declared finished while the window server still had the
    /// target app in front, and activating an app that is already in front does nothing: the
    /// switch just did not happen, 2 times in 10 from a fullscreen Space.
    static func isFront(pid: pid_t) -> Bool? {
        guard let calls = calls else { return nil }
        var front = ProcessSerialNumber()
        var wanted = ProcessSerialNumber()
        guard calls.getFrontProcess(&front) == .success,
              calls.getProcessForPID(pid, &wanted) == noErr
        else { return nil }
        return front.highLongOfPSN == wanted.highLongOfPSN && front.lowLongOfPSN == wanted.lowLongOfPSN
    }

    /// True if every call succeeded. The app ends up frontmost; see the note above.
    static func makeKey(windowID: CGWindowID, pid: pid_t) -> Bool {
        guard let calls = calls else { return false }
        var psn = ProcessSerialNumber()
        guard calls.getProcessForPID(pid, &psn) == noErr,
              calls.setFrontProcess(&psn, windowID, 0x200) == .success // kCPSUserGenerated
        else { return false }

        // The key-window event record, laid out as the window server expects it.
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: windowID.littleEndian) { id in
            for (offset, byte) in id.enumerated() { bytes[0x3c + offset] = byte }
        }
        for offset in 0x20..<0x30 { bytes[offset] = 0xff }
        bytes[0x08] = 0x01
        let down = calls.postEventRecord(&psn, &bytes)
        bytes[0x08] = 0x02
        let up = calls.postEventRecord(&psn, &bytes)
        return down == .success && up == .success
    }
}

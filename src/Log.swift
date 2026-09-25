import Foundation

private let logClock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

/// Written to stderr, which the LaunchAgent sends to ~/Library/Logs/com.halvor.machotkeys.log.
///
/// Callable from any thread: thumbnails and the AX queries log from background queues, and
/// DateFormatter is thread safe for formatting.
func log(_ message: String) {
    let line = "\(logClock.string(from: Date())) mac-hotkeys: \(message)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
}

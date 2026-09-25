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

/// Starts the log afresh at launch once it passes 5MB.
///
/// Every open writes a line, and the agent runs for months between reinstalls, which is the only
/// other time the log is cleared. launchd holds the file open as stderr, so it is truncated in
/// place, and the write position is reset for the case where it was not opened for appending.
func trimLogIfLarge(limit: off_t = 5_000_000) {
    var info = stat()
    guard fstat(STDERR_FILENO, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size > limit else { return }
    guard ftruncate(STDERR_FILENO, 0) == 0 else { return }
    lseek(STDERR_FILENO, 0, SEEK_SET)
    log("log passed \(limit / 1_000_000)MB and was started afresh")
}

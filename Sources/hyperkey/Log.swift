import Foundation

/// Gated debug logging.
///
/// This app is an `LSUIElement` agent normally started via `open`, so anything
/// written to stderr goes nowhere — there is no terminal attached and launchd
/// is not the parent. `os_log`/`NSLog` output also proved unreliable to read
/// back for this process. So debug output goes to a plain file instead.
///
/// Off by default; enable with either:
///   defaults write com.feedthejim.hyperkey debugLogging -bool true   (persistent)
///   HYPERKEY_DEBUG=1                                                 (per-launch)
///
/// `just debug-on` / `just debug-off` / `just logs` wrap this.
enum Log {
    static let path = "/tmp/hyperkey.log"

    /// Resolved once: a per-event UserDefaults lookup in the event tap callback
    /// would be a syscall on every keystroke.
    private static let enabled: Bool = {
        if ProcessInfo.processInfo.environment["HYPERKEY_DEBUG"] != nil { return true }
        return UserDefaults.standard.bool(forKey: "debugLogging")
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static var isEnabled: Bool { enabled }

    static func debug(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        write(message())
    }

    /// Always written, regardless of the flag — for startup state and failures
    /// a user would need to diagnose anything at all.
    static func info(_ message: @autoclosure () -> String) {
        write(message())
    }

    private static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

import Foundation

/// App-owned rolling debug log for field diagnostics. Unified logging drops
/// .debug/.info messages by default and OSLogStore is unreliable on user
/// machines, so when the user enables debug logging we append to a plain-text
/// file they can send us. Never call from the real-time audio callback.
final class DebugLogger: @unchecked Sendable {
    static let shared = DebugLogger()

    static let defaultsKey = "DebugLoggingEnabled"
    private static let maxLogFileBytes: UInt64 = 5 * 1024 * 1024

    let logsDirectory: URL
    let logFileURL: URL

    private let queue = DispatchQueue(label: "com.arcusis.zerm.debuglogger", qos: .utility)
    private let enabledLock = NSLock()
    private var _isEnabled: Bool

    // Accessed on `queue` only
    private var fileHandle: FileHandle?
    private var fileBytes: UInt64 = 0
    private var didWriteBanner = false
    private let timestampFormatter: DateFormatter

    var isEnabled: Bool {
        enabledLock.lock()
        defer { enabledLock.unlock() }
        return _isEnabled
    }

    private init() {
        let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.arcusis.zerm")
        logsDirectory = appSupportDirectory.appendingPathComponent("Logs")
        logFileURL = logsDirectory.appendingPathComponent("zerm-debug.log")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        timestampFormatter = formatter

        _isEnabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(defaultsChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    func log(_ category: String, _ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let line = message()
        queue.async { [self] in
            append(category: category, message: line)
        }
    }

    @objc private func defaultsChanged() {
        let newValue = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        enabledLock.lock()
        let changed = _isEnabled != newValue
        _isEnabled = newValue
        enabledLock.unlock()
        if changed {
            queue.async { [self] in
                append(category: "DebugLogger", message: "debug logging \(newValue ? "enabled" : "disabled")")
            }
        }
    }

    // MARK: - File writing (on `queue` only)

    private func append(category: String, message: String) {
        if !didWriteBanner {
            didWriteBanner = true
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
            writeLine(category: "DebugLogger", message: "=== Zerm \(version) (\(build)) — macOS \(ProcessInfo.processInfo.operatingSystemVersionString) ===")
        }
        writeLine(category: category, message: message)
    }

    private func writeLine(category: String, message: String) {
        guard let handle = openFileIfNeeded() else { return }
        let line = "\(timestampFormatter.string(from: Date())) [\(category)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        do {
            try handle.write(contentsOf: data)
            fileBytes += UInt64(data.count)
            if fileBytes > Self.maxLogFileBytes {
                rotate()
            }
        } catch {
            fileHandle = nil
        }
    }

    private func openFileIfNeeded() -> FileHandle? {
        if let fileHandle { return fileHandle }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: logFileURL.path) {
                fileManager.createFile(atPath: logFileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logFileURL)
            fileBytes = try handle.seekToEnd()
            fileHandle = handle
            return handle
        } catch {
            return nil
        }
    }

    private func rotate() {
        try? fileHandle?.close()
        fileHandle = nil
        let previousURL = logsDirectory.appendingPathComponent("zerm-debug.old.log")
        try? FileManager.default.removeItem(at: previousURL)
        try? FileManager.default.moveItem(at: logFileURL, to: previousURL)
        fileBytes = 0
    }
}

import Foundation

/// A persistent, rotating, line-oriented log in the App Group container,
/// shared by the app and its extensions (one file each: `app`, `extension`,
/// `intents`). What the in-app
/// log view shows is lost with the process; this survives a crash or a
/// kill and is uploaded to the dev server on the next launch
/// (`DiagnosticsClient`), so the lines that explain a termination are on
/// the developer's machine without touching the phone.
public final class FileLog: @unchecked Sendable {
    public let url: URL
    private let maxBytes: Int
    private let lock = NSLock()
    private var handle: FileHandle?
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f
    }()

    /// `name` is the file's stem (`app`, `extension`, `intents`). Nil when the App
    /// Group container is unavailable (misconfigured entitlements).
    public init?(name: String, appGroup: String = DiallerIDs.appGroup, maxBytes: Int = 2_000_000) {
        guard let dir = FileLog.directory(appGroup: appGroup) else { return nil }
        url = dir.appendingPathComponent("\(name).log")
        self.maxBytes = maxBytes
    }

    /// The logs directory inside the App Group container.
    public static func directory(appGroup: String = DiallerIDs.appGroup) -> URL? {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        let dir = base.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Appends one timestamped line. Rotates to `<name>.1.log` past `maxBytes`.
    ///
    /// The file is shared across processes: the app drains (deletes) the
    /// extension's file at launch while the extension may still hold it
    /// open. A handle to a deleted file keeps accepting writes that nobody
    /// will ever read — the extension's log went dark after the first drain
    /// (2026-09-13). So every write checks the file still exists at its
    /// path and reopens otherwise.
    public func write(_ line: String) {
        let text = "\(stamp.string(from: Date())) \(line)\n"
        guard let data = text.data(using: .utf8) else { return }
        lock.withLock {
            if handle != nil, !FileManager.default.fileExists(atPath: url.path) {
                try? handle?.close()
                handle = nil
            }
            if handle == nil { open() }
            guard let h = handle else { return }
            do {
                try h.write(contentsOf: data)
                if try h.offset() > UInt64(maxBytes) { rotateLocked() }
            } catch {
                handle = nil
            }
        }
    }

    /// Everything currently on disk (previous rotation first), then empties
    /// the live file. Used by the uploader: what it returns is what it sends.
    public func drain() -> Data? {
        lock.withLock {
            var out = Data()
            let prev = url.deletingPathExtension().appendingPathExtension("1.log")
            if let d = try? Data(contentsOf: prev) { out.append(d); try? FileManager.default.removeItem(at: prev) }
            if let d = try? Data(contentsOf: url) { out.append(d) }
            try? handle?.close()
            handle = nil
            try? FileManager.default.removeItem(at: url)
            return out.isEmpty ? nil : out
        }
    }

    private func open() {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        // stderr goes into this file too. The engine's watchdog reports a
        // loop thread that stalls or spins — and its backtrace, from a
        // signal handler, where only write(2) to a descriptor is safe — on
        // stderr; so do libre's own warnings and the Swift runtime's. On a
        // device none of that reaches anyone: the process was killed for
        // 49 s at 100 % CPU on 2026-09-20 and the dump that would have named
        // the spinning handler went to a stderr nobody was reading. Redone
        // on every reopen (rotation, a drain), since the descriptor follows
        // the file it was pointed at.
        if let fd = handle?.fileDescriptor {
            _ = dup2(fd, STDERR_FILENO)
        }
    }

    private func rotateLocked() {
        try? handle?.close()
        handle = nil
        let prev = url.deletingPathExtension().appendingPathExtension("1.log")
        try? FileManager.default.removeItem(at: prev)
        try? FileManager.default.moveItem(at: url, to: prev)
        open()
    }
}

/// Uploads diagnostics to the dev server's `POST /v1/diag` with the device
/// credential (same trust switch as the directory client). Files that fail
/// to upload stay queued in the App Group and go on the next attempt.
public struct DiagnosticsClient: Sendable {
    public let base: URL
    public let deviceID: String
    public let token: String
    public let acceptAnyCertificate: Bool
    /// The pinned certificate from enrolment, when there is one.
    public let certSHA256: String?

    public init(base: URL, deviceID: String, token: String, acceptAnyCertificate: Bool, certSHA256: String? = nil) {
        self.base = base
        self.deviceID = deviceID
        self.token = token
        self.acceptAnyCertificate = acceptAnyCertificate
        self.certSHA256 = certSHA256
    }

    /// The queue directory: `<App Group>/diag-pending/`.
    public static func pendingDirectory(appGroup: String = DiallerIDs.appGroup) -> URL? {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        let dir = base.appendingPathComponent("diag-pending", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Queues one item: `<time>_<kind>[_<name>]` in the pending directory
    /// ("_" because kinds contain "-"). Returns the queued file's URL.
    @discardableResult
    public static func enqueue(kind: String, name: String? = nil, data: Data, appGroup: String = DiallerIDs.appGroup) -> URL? {
        guard let dir = pendingDirectory(appGroup: appGroup) else { return nil }
        // No dashes in the stamp: the file name is split on "-" when flushed.
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
        var file = "\(stamp)_\(kind)"
        if let name, !name.isEmpty { file += "_" + name.replacingOccurrences(of: "/", with: "-") }
        let url = dir.appendingPathComponent(file)
        return (try? data.write(to: url, options: .atomic)) == nil ? nil : url
    }

    /// Sends one payload.
    public func upload(kind: String, name: String?, data: Data) async throws {
        var req = URLRequest(url: base.appendingPathComponent("v1/diag"))
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue(deviceID, forHTTPHeaderField: "X-Device-ID")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(kind, forHTTPHeaderField: "X-Diag-Kind")
        if let name, !name.isEmpty { req.setValue(name, forHTTPHeaderField: "X-Diag-Name") }
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let session = URLSession.forEndpoint(pin: certSHA256, acceptAny: acceptAnyCertificate)
        let (_, response) = try await session.upload(for: req, from: data)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    /// Uploads everything queued, oldest first; a file is deleted only after
    /// the server accepted it. Returns (sent, failed).
    @discardableResult
    public func flush(appGroup: String = DiallerIDs.appGroup) async -> (sent: Int, failed: Int) {
        guard let dir = DiagnosticsClient.pendingDirectory(appGroup: appGroup),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return (0, 0) }
        var sent = 0, failed = 0
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            // "<stamp>_<kind>[_<name>]"
            let parts = url.lastPathComponent.split(separator: "_", maxSplits: 2).map(String.init)
            guard parts.count >= 2, let data = try? Data(contentsOf: url) else { continue }
            let kind = parts[1], name = parts.count > 2 ? parts[2] : nil
            do {
                try await upload(kind: kind, name: name, data: data)
                try? FileManager.default.removeItem(at: url)
                sent += 1
            } catch {
                failed += 1
            }
        }
        return (sent, failed)
    }
}

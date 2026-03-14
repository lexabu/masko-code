import Foundation

/// Tails Codex session JSONL logs and maps them to `ClaudeEvent` for reuse in the existing pipeline.
final class CodexSessionMonitor {
    private struct TrackedFile {
        var offset: UInt64
        var partialLine: String
        let sessionId: String?
    }

    static var defaultSessionsRoot: URL {
        let base: URL
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !codexHome.isEmpty {
            base = URL(fileURLWithPath: codexHome)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        }
        return base.appendingPathComponent("sessions")
    }

    private let rootURL: URL
    private let pollInterval: TimeInterval
    private let bootstrapRecentWindow: TimeInterval
    private let bootstrapTailBytes: UInt64
    private var trackedFiles: [String: TrackedFile] = [:]
    private var sessionContexts: [String: CodexSessionContext] = [:]
    private var timer: Timer?

    var onEventReceived: ((ClaudeEvent) -> Void)?

    init(
        rootURL: URL = CodexSessionMonitor.defaultSessionsRoot,
        pollInterval: TimeInterval = 1.0,
        bootstrapRecentWindow: TimeInterval = 15 * 60,
        bootstrapTailBytes: UInt64 = 262_144
    ) {
        self.rootURL = rootURL
        self.pollInterval = pollInterval
        self.bootstrapRecentWindow = bootstrapRecentWindow
        self.bootstrapTailBytes = bootstrapTailBytes
    }

    func start(bootstrapRecentFiles: Bool = true) {
        guard timer == nil else { return }
        bootstrapExistingFiles(bootstrapRecentFiles: bootstrapRecentFiles)
        let t = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.pollOnce()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        trackedFiles.removeAll()
        sessionContexts.removeAll()
    }

    /// Internal for deterministic tests.
    func pollOnce() {
        let files = sessionFiles()
        let existingPaths = Set(files.map(\.path))

        for path in trackedFiles.keys where !existingPaths.contains(path) {
            trackedFiles.removeValue(forKey: path)
        }

        for fileURL in files where trackedFiles[fileURL.path] == nil {
            register(fileURL: fileURL, startAtEnd: false, bootstrapRecentFile: false)
        }

        for fileURL in files {
            processAppendedData(for: fileURL)
        }
    }

    private func bootstrapExistingFiles(bootstrapRecentFiles: Bool) {
        for fileURL in sessionFiles() {
            register(fileURL: fileURL, startAtEnd: true, bootstrapRecentFile: bootstrapRecentFiles)
        }
    }

    private func sessionFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var urls: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            urls.append(url)
        }
        return urls.sorted { $0.path < $1.path }
    }

    private func register(fileURL: URL, startAtEnd: Bool, bootstrapRecentFile shouldBootstrapRecentFile: Bool) {
        let size = fileSize(fileURL)
        let sessionId = CodexEventMapper.sessionId(fromFileURL: fileURL)
        trackedFiles[fileURL.path] = TrackedFile(
            offset: startAtEnd ? size : 0,
            partialLine: "",
            sessionId: sessionId
        )
        if let sessionId, sessionContexts[sessionId] == nil {
            sessionContexts[sessionId] = CodexSessionContext(
                sessionId: sessionId,
                cwd: nil,
                source: nil,
                originator: nil
            )
        }

        // Preserve source/cwd context for existing files by peeking at session_meta.
        if let firstLine = readFirstLine(of: fileURL, maxBytes: 131_072),
           let trackedSessionId = sessionId {
            let result = CodexEventMapper.parse(
                line: firstLine,
                fileURL: fileURL,
                context: sessionContexts[trackedSessionId]
            )
            if let updated = result.context {
                if let existing = sessionContexts[updated.sessionId] {
                    sessionContexts[updated.sessionId] = existing.merged(with: updated)
                } else {
                    sessionContexts[updated.sessionId] = updated
                }
            }
        }

        if startAtEnd, shouldBootstrapRecentFile {
            bootstrapRecentFile(fileURL: fileURL)
        }
    }

    private func processAppendedData(for fileURL: URL) {
        guard var tracked = trackedFiles[fileURL.path] else { return }
        let size = fileSize(fileURL)

        if size < tracked.offset {
            tracked.offset = 0
            tracked.partialLine = ""
        }
        guard size > tracked.offset else {
            trackedFiles[fileURL.path] = tracked
            return
        }

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
        defer { handle.closeFile() }

        do {
            try handle.seek(toOffset: tracked.offset)
        } catch {
            trackedFiles[fileURL.path] = tracked
            return
        }

        let data = handle.readDataToEndOfFile()
        tracked.offset = size
        guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else {
            trackedFiles[fileURL.path] = tracked
            return
        }

        let combined = tracked.partialLine + chunk
        let lines = combined.split(separator: "\n", omittingEmptySubsequences: false)

        let completeLines: [Substring]
        if combined.hasSuffix("\n") {
            tracked.partialLine = ""
            completeLines = lines
        } else {
            tracked.partialLine = String(lines.last ?? "")
            completeLines = Array(lines.dropLast())
        }

        trackedFiles[fileURL.path] = tracked

        for lineSlice in completeLines {
            let line = lineSlice.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            processLine(line, fileURL: fileURL, trackedSessionId: tracked.sessionId)
        }
    }

    private func processLine(_ line: String, fileURL: URL, trackedSessionId: String?) {
        let context = trackedSessionId.flatMap { sessionContexts[$0] }
        let result = CodexEventMapper.parse(line: line, fileURL: fileURL, context: context)

        if let updated = result.context {
            if let existing = sessionContexts[updated.sessionId] {
                sessionContexts[updated.sessionId] = existing.merged(with: updated)
            } else {
                sessionContexts[updated.sessionId] = updated
            }
        }

        for event in result.events {
            onEventReceived?(event)
        }
    }

    private func fileSize(_ fileURL: URL) -> UInt64 {
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
        return UInt64(values?.fileSize ?? 0)
    }

    private func bootstrapRecentFile(fileURL: URL) {
        let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
        let modifiedAt = values?.contentModificationDate ?? .distantPast
        guard Date().timeIntervalSince(modifiedAt) <= bootstrapRecentWindow else { return }

        let lines = readTailLines(of: fileURL, maxBytes: bootstrapTailBytes)
        guard !lines.isEmpty else { return }

        let trackedSessionId = trackedFiles[fileURL.path]?.sessionId
        for line in lines {
            processLine(line, fileURL: fileURL, trackedSessionId: trackedSessionId)
        }
    }

    private func readTailLines(of fileURL: URL, maxBytes: UInt64) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { handle.closeFile() }

        let size = handle.seekToEndOfFile()
        let readSize = min(size, maxBytes)
        handle.seek(toFileOffset: size - readSize)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    private func readFirstLine(of fileURL: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { handle.closeFile() }
        let data = handle.readData(ofLength: maxBytes)
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return nil }
        return text.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

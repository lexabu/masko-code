import Foundation
import XCTest
@testable import masko_code

final class CodexSessionMonitorTests: XCTestCase {
    func testStartBootstrapsRecentExistingFile() throws {
        let root = try makeTempSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let fileURL = root
            .appendingPathComponent("2026")
            .appendingPathComponent("03")
            .appendingPathComponent("14")
            .appendingPathComponent("rollout-2026-03-14T01-24-49-\(sessionId).jsonl")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeLines([
            #"{"type":"session_meta","payload":{"id":"019cd686-3b91-78a1-9356-21b475548352","cwd":"/Users/test/project","source":"cli","originator":"codex_cli_rs"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn_bootstrap"}}"#,
        ], to: fileURL)

        let monitor = CodexSessionMonitor(
            rootURL: root,
            pollInterval: 999,
            bootstrapRecentWindow: 3_600
        )
        var events: [ClaudeEvent] = []
        monitor.onEventReceived = { events.append($0) }

        monitor.start()
        defer { monitor.stop() }

        XCTAssertEqual(events.map(\.hookEventName), [
            HookEventType.sessionStart.rawValue,
            HookEventType.userPromptSubmit.rawValue,
        ])
    }

    func testStartSkipsOldExistingFileBootstrap() throws {
        let root = try makeTempSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let fileURL = root
            .appendingPathComponent("2026")
            .appendingPathComponent("03")
            .appendingPathComponent("14")
            .appendingPathComponent("rollout-2026-03-14T01-24-49-\(sessionId).jsonl")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeLines([
            #"{"type":"session_meta","payload":{"id":"019cd686-3b91-78a1-9356-21b475548352","cwd":"/Users/test/project","source":"cli","originator":"codex_cli_rs"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn_bootstrap"}}"#,
        ], to: fileURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-7_200)],
            ofItemAtPath: fileURL.path
        )

        let monitor = CodexSessionMonitor(
            rootURL: root,
            pollInterval: 999,
            bootstrapRecentWindow: 60
        )
        var events: [ClaudeEvent] = []
        monitor.onEventReceived = { events.append($0) }

        monitor.start()
        defer { monitor.stop() }

        XCTAssertTrue(events.isEmpty)
    }

    func testStartPreservesExistingSessionMetaContextForFutureAppends() throws {
        let root = try makeTempSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let fileURL = root
            .appendingPathComponent("2026")
            .appendingPathComponent("03")
            .appendingPathComponent("14")
            .appendingPathComponent("rollout-2026-03-14T01-24-49-\(sessionId).jsonl")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeLines([
            #"{"type":"session_meta","payload":{"id":"019cd686-3b91-78a1-9356-21b475548352","cwd":"/Users/test/project","source":"vscode","originator":"Codex Desktop"}}"#,
        ], to: fileURL)

        let monitor = CodexSessionMonitor(
            rootURL: root,
            pollInterval: 999,
            bootstrapRecentWindow: 0
        )
        var events: [ClaudeEvent] = []
        monitor.onEventReceived = { events.append($0) }

        monitor.start()
        defer { monitor.stop() }
        XCTAssertTrue(events.isEmpty)

        try appendLine(#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn_meta"}}"#, to: fileURL)
        monitor.pollOnce()

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].hookEventName, HookEventType.userPromptSubmit.rawValue)
        XCTAssertEqual(events[0].source, "codex-desktop")
        XCTAssertEqual(events[0].cwd, "/Users/test/project")
    }

    func testStartCanDisableBootstrapForRecentFiles() throws {
        let root = try makeTempSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let fileURL = root
            .appendingPathComponent("2026")
            .appendingPathComponent("03")
            .appendingPathComponent("14")
            .appendingPathComponent("rollout-2026-03-14T01-24-49-\(sessionId).jsonl")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeLines([
            #"{"type":"session_meta","payload":{"id":"019cd686-3b91-78a1-9356-21b475548352","cwd":"/Users/test/project","source":"cli","originator":"codex_cli_rs"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn_recent"}}"#,
        ], to: fileURL)

        let monitor = CodexSessionMonitor(
            rootURL: root,
            pollInterval: 999,
            bootstrapRecentWindow: 3_600
        )
        var events: [ClaudeEvent] = []
        monitor.onEventReceived = { events.append($0) }

        monitor.start(bootstrapRecentFiles: false)
        defer { monitor.stop() }

        XCTAssertTrue(events.isEmpty)
    }

    func testMonitorParsesNewSessionFile() throws {
        let root = try makeTempSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let fileURL = root
            .appendingPathComponent("2026")
            .appendingPathComponent("03")
            .appendingPathComponent("14")
            .appendingPathComponent("rollout-2026-03-14T01-24-49-\(sessionId).jsonl")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let lines = [
            #"{"type":"session_meta","payload":{"id":"019cd686-3b91-78a1-9356-21b475548352","cwd":"/Users/test/project","source":"cli","originator":"codex_cli_rs"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn_1"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call_1","arguments":"{\"cmd\":\"pwd\"}"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"call_1","status":"completed","output":"{\"exit_code\":0}"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn_1","last_agent_message":"Done"}}"#,
        ]
        try writeLines(lines, to: fileURL)

        let monitor = CodexSessionMonitor(rootURL: root, pollInterval: 999)
        var events: [ClaudeEvent] = []
        monitor.onEventReceived = { events.append($0) }

        monitor.pollOnce()

        XCTAssertEqual(events.map(\.hookEventName), [
            HookEventType.sessionStart.rawValue,
            HookEventType.userPromptSubmit.rawValue,
            HookEventType.preToolUse.rawValue,
            HookEventType.postToolUse.rawValue,
            HookEventType.stop.rawValue,
        ])
        XCTAssertEqual(events.first?.source, "codex-cli")
        XCTAssertEqual(events.last?.lastAssistantMessage, "Done")
    }

    func testMonitorOnlyEmitsAppendedLines() throws {
        let root = try makeTempSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let fileURL = root
            .appendingPathComponent("2026")
            .appendingPathComponent("03")
            .appendingPathComponent("14")
            .appendingPathComponent("rollout-2026-03-14T01-24-49-\(sessionId).jsonl")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try writeLines([
            #"{"type":"session_meta","payload":{"id":"019cd686-3b91-78a1-9356-21b475548352","cwd":"/Users/test/project","source":"cli","originator":"codex_cli_rs"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn_1"}}"#,
        ], to: fileURL)

        let monitor = CodexSessionMonitor(rootURL: root, pollInterval: 999)
        var events: [ClaudeEvent] = []
        monitor.onEventReceived = { events.append($0) }

        monitor.pollOnce()
        XCTAssertEqual(events.count, 2)

        try appendLine(#"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn_1","last_agent_message":"Done"}}"#, to: fileURL)
        monitor.pollOnce()

        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.last?.hookEventName, HookEventType.stop.rawValue)
    }

    private func makeTempSessionsRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("masko-codex-tests-\(UUID().uuidString)")
            .appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeLines(_ lines: [String], to fileURL: URL) throws {
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func appendLine(_ line: String, to fileURL: URL) throws {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        let handle = try FileHandle(forWritingTo: fileURL)
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    }
}

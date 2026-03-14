import Foundation
import XCTest
@testable import masko_code

final class CodexEventMapperTests: XCTestCase {
    func testSessionMetaMapsToSessionStartForDesktop() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")
        let line = """
        {"type":"session_meta","payload":{"id":"\(sessionId)","cwd":"/Users/test/project","source":"vscode","originator":"Codex Desktop","cli_version":"0.108.0-alpha.12"}}
        """

        let result = CodexEventMapper.parse(line: line, fileURL: fileURL, context: nil)

        XCTAssertEqual(result.context?.sessionId, sessionId)
        XCTAssertEqual(result.context?.cwd, "/Users/test/project")
        XCTAssertEqual(result.context?.normalizedSource, "codex-desktop")
        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events.first?.hookEventName, HookEventType.sessionStart.rawValue)
        XCTAssertEqual(result.events.first?.sessionId, sessionId)
        XCTAssertEqual(result.events.first?.source, "codex-desktop")
    }

    func testSessionMetaMapsToDesktopForExecSourceWhenOriginatorIsDesktop() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")
        let line = """
        {"type":"session_meta","payload":{"id":"\(sessionId)","cwd":"/Users/test/project","source":"exec","originator":"Codex Desktop"}}
        """

        let result = CodexEventMapper.parse(line: line, fileURL: fileURL, context: nil)

        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events.first?.source, "codex-desktop")
    }

    func testSessionMetaMapsToDesktopForVscodeVariantSource() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")
        let line = """
        {"type":"session_meta","payload":{"id":"\(sessionId)","cwd":"/Users/test/project","source":"vscode-insiders"}}
        """

        let result = CodexEventMapper.parse(line: line, fileURL: fileURL, context: nil)

        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events.first?.source, "codex-desktop")
    }

    func testTaskEventsMapToRunningAndStop() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let context = CodexSessionContext(
            sessionId: sessionId,
            cwd: "/Users/test/project",
            source: "cli",
            originator: "codex_cli_rs"
        )
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")

        let startLine = """
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn_123"}}
        """
        let startResult = CodexEventMapper.parse(line: startLine, fileURL: fileURL, context: context)
        XCTAssertEqual(startResult.events.count, 1)
        XCTAssertEqual(startResult.events.first?.hookEventName, HookEventType.userPromptSubmit.rawValue)
        XCTAssertEqual(startResult.events.first?.taskId, "turn_123")
        XCTAssertEqual(startResult.events.first?.source, "codex-cli")

        let stopLine = """
        {"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn_123","last_agent_message":"Done"}}
        """
        let stopResult = CodexEventMapper.parse(line: stopLine, fileURL: fileURL, context: context)
        XCTAssertEqual(stopResult.events.count, 1)
        XCTAssertEqual(stopResult.events.first?.hookEventName, HookEventType.stop.rawValue)
        XCTAssertEqual(stopResult.events.first?.reason, "completed")
        XCTAssertEqual(stopResult.events.first?.lastAssistantMessage, "Done")
    }

    func testCompactedEventMapsToPreCompact() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let context = CodexSessionContext(
            sessionId: sessionId,
            cwd: "/Users/test/project",
            source: "cli",
            originator: "codex_cli_rs"
        )
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")
        let line = """
        {"type":"compacted","payload":{"message":"context compacted"}}
        """

        let result = CodexEventMapper.parse(line: line, fileURL: fileURL, context: context)

        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events.first?.hookEventName, HookEventType.preCompact.rawValue)
        XCTAssertEqual(result.events.first?.source, "codex-cli")
        XCTAssertEqual(result.events.first?.reason, "context_compacted")
    }

    func testFunctionCallMapsToToolEvents() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let context = CodexSessionContext(
            sessionId: sessionId,
            cwd: "/Users/test/project",
            source: "cli",
            originator: "codex_cli_rs"
        )
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")

        let callLine = #"""
        {"type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call_abc","arguments":"{\"cmd\":\"ls -la\"}"}}
        """#
        let callResult = CodexEventMapper.parse(line: callLine, fileURL: fileURL, context: context)
        XCTAssertEqual(callResult.events.count, 1)
        let preTool = try XCTUnwrap(callResult.events.first)
        XCTAssertEqual(preTool.hookEventName, HookEventType.preToolUse.rawValue)
        XCTAssertEqual(preTool.toolName, "exec_command")
        XCTAssertEqual(preTool.toolUseId, "call_abc")
        XCTAssertEqual(preTool.toolInput?["cmd"]?.stringValue, "ls -la")

        let outputLine = #"""
        {"type":"response_item","payload":{"type":"function_call_output","call_id":"call_abc","status":"completed","output":"{\"exit_code\":0}"}}
        """#
        let outputResult = CodexEventMapper.parse(line: outputLine, fileURL: fileURL, context: context)
        XCTAssertEqual(outputResult.events.count, 1)
        let postTool = try XCTUnwrap(outputResult.events.first)
        XCTAssertEqual(postTool.hookEventName, HookEventType.postToolUse.rawValue)
        XCTAssertEqual(postTool.toolUseId, "call_abc")
        XCTAssertEqual(postTool.toolResponse?["exit_code"]?.intValue, 0)
    }

    func testFunctionCallWithEscalatedSandboxEmitsPermissionRequest() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let context = CodexSessionContext(
            sessionId: sessionId,
            cwd: "/Users/test/project",
            source: "cli",
            originator: "codex_cli_rs"
        )
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")
        let line = #"""
        {"type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call_perm_1","arguments":"{\"cmd\":\"git push\",\"sandbox_permissions\":\"require_escalated\",\"justification\":\"Need network access to push branch\"}"}}
        """#

        let result = CodexEventMapper.parse(line: line, fileURL: fileURL, context: context)

        XCTAssertEqual(result.events.count, 2)
        let preTool = try XCTUnwrap(result.events.first)
        XCTAssertEqual(preTool.hookEventName, HookEventType.preToolUse.rawValue)
        XCTAssertEqual(preTool.toolUseId, "call_perm_1")

        let permission = try XCTUnwrap(result.events.last)
        XCTAssertEqual(permission.hookEventName, HookEventType.permissionRequest.rawValue)
        XCTAssertEqual(permission.toolUseId, "call_perm_1")
        XCTAssertEqual(permission.toolName, "exec_command")
        XCTAssertEqual(permission.message, "Need network access to push branch")
        XCTAssertEqual(permission.toolInput?["sandbox_permissions"]?.stringValue, "require_escalated")
    }

    func testRequestUserInputMapsToAskUserQuestionPermissionRequest() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let context = CodexSessionContext(
            sessionId: sessionId,
            cwd: "/Users/test/project",
            source: "cli",
            originator: "codex_cli_rs"
        )
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")
        let line = #"""
        {"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"call_question_1","arguments":"{\"questions\":[{\"id\":\"choice\",\"question\":\"Which option should we use?\",\"options\":[{\"label\":\"A\",\"description\":\"First\"},{\"label\":\"B\",\"description\":\"Second\"}]}]}"}}
        """#

        let result = CodexEventMapper.parse(line: line, fileURL: fileURL, context: context)

        XCTAssertEqual(result.events.count, 2)
        let preTool = try XCTUnwrap(result.events.first)
        XCTAssertEqual(preTool.hookEventName, HookEventType.preToolUse.rawValue)
        XCTAssertEqual(preTool.toolName, "request_user_input")
        XCTAssertEqual(preTool.toolUseId, "call_question_1")

        let permission = try XCTUnwrap(result.events.last)
        XCTAssertEqual(permission.hookEventName, HookEventType.permissionRequest.rawValue)
        XCTAssertEqual(permission.toolName, "AskUserQuestion")
        XCTAssertEqual(permission.toolUseId, "call_question_1")
        XCTAssertEqual(permission.message, "Which option should we use?")
        XCTAssertNotNil(permission.toolInput?["questions"])
    }

    func testSessionIdFallsBackToFilename() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")
        let line = """
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn_456"}}
        """

        let result = CodexEventMapper.parse(line: line, fileURL: fileURL, context: nil)

        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events.first?.sessionId, sessionId)
        XCTAssertEqual(result.events.first?.source, "codex")
    }

    func testParsesLatestLocalCodexLogTailWhenAvailable() throws {
        let root = CodexSessionMonitor.defaultSessionsRoot
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("Local Codex sessions directory not found")
        }
        guard let latest = latestSessionFile(in: root) else {
            throw XCTSkip("No local Codex session files found")
        }

        let lines = try tailLines(of: latest, maxBytes: 262_144)
        var context: CodexSessionContext?
        var mappedEvents = 0

        for line in lines {
            let result = CodexEventMapper.parse(line: line, fileURL: latest, context: context)
            if let updatedContext = result.context {
                context = updatedContext
            }
            mappedEvents += result.events.count
        }

        XCTAssertGreaterThan(mappedEvents, 0, "Expected parser to map at least one local Codex log event")
    }

    func testParsesLatestLocalCodexDesktopLogWhenAvailable() throws {
        let root = CodexSessionMonitor.defaultSessionsRoot
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("Local Codex sessions directory not found")
        }
        guard let latestDesktop = latestSessionFile(in: root, matching: { fileURL in
            guard let prefix = try? readPrefix(of: fileURL, maxBytes: 131_072),
                  let text = String(data: prefix, encoding: .utf8) else {
                return false
            }
            return text.contains("\"source\":\"vscode\"") || text.contains("\"originator\":\"Codex Desktop\"")
        }) else {
            throw XCTSkip("No local Codex Desktop session files found")
        }

        let lines = try tailLines(of: latestDesktop, maxBytes: 262_144)
        var context: CodexSessionContext?
        var mappedEvents = 0

        for line in lines {
            let result = CodexEventMapper.parse(line: line, fileURL: latestDesktop, context: context)
            if let updatedContext = result.context {
                context = updatedContext
            }
            mappedEvents += result.events.count
        }

        XCTAssertGreaterThan(mappedEvents, 0, "Expected parser to map at least one local Codex Desktop log event")
    }

    private func latestSessionFile(in root: URL) -> URL? {
        latestSessionFile(in: root, matching: { _ in true })
    }

    private func latestSessionFile(in root: URL, matching predicate: (URL) -> Bool) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var candidates: [URL] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            if predicate(fileURL) {
                candidates.append(fileURL)
            }
        }
        return candidates.max { lhs, rhs in
            let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return leftDate < rightDate
        }
    }

    private func tailLines(of fileURL: URL, maxBytes: UInt64) throws -> [String] {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { handle.closeFile() }

        let size = handle.seekToEndOfFile()
        let readSize = min(size, maxBytes)
        handle.seek(toFileOffset: size - readSize)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    private func readPrefix(of fileURL: URL, maxBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { handle.closeFile() }
        return handle.readData(ofLength: maxBytes)
    }
}

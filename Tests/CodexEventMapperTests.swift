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

    func testSessionMetaMapsExecSourceToCliWhenOriginatorIsCodexExec() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")
        let line = """
        {"type":"session_meta","payload":{"id":"\(sessionId)","cwd":"/Users/test/project","source":"exec","originator":"codex_exec"}}
        """

        let result = CodexEventMapper.parse(line: line, fileURL: fileURL, context: nil)

        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events.first?.source, "codex-cli")
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
        XCTAssertEqual(stopResult.events.count, 2)
        XCTAssertEqual(stopResult.events.first?.hookEventName, HookEventType.stop.rawValue)
        XCTAssertEqual(stopResult.events.first?.reason, "completed")
        XCTAssertEqual(stopResult.events.first?.lastAssistantMessage, "Done")
        XCTAssertEqual(stopResult.events.last?.hookEventName, HookEventType.taskCompleted.rawValue)
        XCTAssertEqual(stopResult.events.last?.taskId, "turn_123")
        XCTAssertEqual(stopResult.events.last?.taskSubject, "Done")
    }

    func testTaskCompleteQuestionOnlyEmitsStop() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let context = CodexSessionContext(
            sessionId: sessionId,
            cwd: "/Users/test/project",
            source: "cli",
            originator: "codex_cli_rs"
        )
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")
        let line = """
        {"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn_question","last_agent_message":"Which remote should I use for the dry-run push?"}}
        """

        let result = CodexEventMapper.parse(line: line, fileURL: fileURL, context: context)

        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events.first?.hookEventName, HookEventType.stop.rawValue)
        XCTAssertEqual(result.events.first?.lastAssistantMessage, "Which remote should I use for the dry-run push?")
    }

    func testEventMsgRequestUserInputMapsToQuestionPermissionRequest() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let context = CodexSessionContext(
            sessionId: sessionId,
            cwd: "/Users/test/project",
            source: "cli",
            originator: "codex_cli_rs"
        )
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")
        let line = #"""
        {"type":"event_msg","payload":{"type":"request_user_input","call_id":"call_q_evt","questions":[{"id":"q1","question":"Pick one option","options":[{"label":"A","description":"First"}]}]}}
        """#

        let result = CodexEventMapper.parse(line: line, fileURL: fileURL, context: context)

        XCTAssertEqual(result.events.count, 1)
        let event = try XCTUnwrap(result.events.first)
        XCTAssertEqual(event.hookEventName, HookEventType.permissionRequest.rawValue)
        XCTAssertEqual(event.toolName, "AskUserQuestion")
        XCTAssertEqual(event.toolUseId, "call_q_evt")
        XCTAssertEqual(event.message, "Pick one option")
        XCTAssertNotNil(event.toolInput?["questions"])
    }

    func testEventMsgExecApprovalRequestMapsToPreToolAndPermission() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let context = CodexSessionContext(
            sessionId: sessionId,
            cwd: "/Users/test/project",
            source: "cli",
            originator: "codex_cli_rs"
        )
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")
        let line = #"""
        {"type":"event_msg","payload":{"type":"exec_approval_request","call_id":"call_exec_evt","command":["git","push"],"cwd":"/Users/test/project","reason":"Need network access to push","parsed_cmd":[]}}
        """#

        let result = CodexEventMapper.parse(line: line, fileURL: fileURL, context: context)

        XCTAssertEqual(result.events.count, 2)
        let preTool = try XCTUnwrap(result.events.first)
        XCTAssertEqual(preTool.hookEventName, HookEventType.preToolUse.rawValue)
        XCTAssertEqual(preTool.toolName, "exec_command")
        XCTAssertEqual(preTool.toolUseId, "call_exec_evt")
        XCTAssertEqual(preTool.toolInput?["cmd"]?.stringValue, "git push")

        let permission = try XCTUnwrap(result.events.last)
        XCTAssertEqual(permission.hookEventName, HookEventType.permissionRequest.rawValue)
        XCTAssertEqual(permission.toolName, "exec_command")
        XCTAssertEqual(permission.toolUseId, "call_exec_evt")
        XCTAssertEqual(permission.toolInput?["sandbox_permissions"]?.stringValue, "require_escalated")
        XCTAssertEqual(permission.message, "Need network access to push")
    }

    func testExecApprovalRequestMapsPrefixRuleToPermissionSuggestion() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let context = CodexSessionContext(
            sessionId: sessionId,
            cwd: "/Users/test/project",
            source: "cli",
            originator: "codex_cli_rs"
        )
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")
        let line = #"""
        {"type":"event_msg","payload":{"type":"exec_approval_request","call_id":"call_exec_prefix","command":["git","push"],"cwd":"/Users/test/project","reason":"Need network access to push","prefix_rule":["git","push"],"parsed_cmd":[]}}
        """#

        let result = CodexEventMapper.parse(line: line, fileURL: fileURL, context: context)

        let permission = try XCTUnwrap(result.events.last)
        let suggestions = try XCTUnwrap(permission.permissionSuggestions?.compactMap { $0.value as? [String: Any] })
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?["type"] as? String, "addRules")
        let rules = try XCTUnwrap(suggestions.first?["rules"] as? [[String: String]])
        XCTAssertEqual(rules.first?["toolName"], "exec_command")
        XCTAssertEqual(rules.first?["ruleContent"], "git push")
    }

    func testEventMsgExecCommandBeginAndEndMapToToolLifecycle() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let context = CodexSessionContext(
            sessionId: sessionId,
            cwd: "/Users/test/project",
            source: "cli",
            originator: "codex_cli_rs"
        )
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")

        let beginLine = #"""
        {"type":"event_msg","payload":{"type":"exec_command_begin","call_id":"call_exec_begin","command":["bash","-lc","ls"],"cwd":"/Users/test/project","parsed_cmd":[],"turn_id":"turn_1"}}
        """#
        let beginResult = CodexEventMapper.parse(line: beginLine, fileURL: fileURL, context: context)
        XCTAssertEqual(beginResult.events.count, 1)
        let preTool = try XCTUnwrap(beginResult.events.first)
        XCTAssertEqual(preTool.hookEventName, HookEventType.preToolUse.rawValue)
        XCTAssertEqual(preTool.toolName, "exec_command")
        XCTAssertEqual(preTool.toolUseId, "call_exec_begin")
        XCTAssertEqual(preTool.toolInput?["cmd"]?.stringValue, "bash -lc ls")

        let endLine = #"""
        {"type":"event_msg","payload":{"type":"exec_command_end","call_id":"call_exec_begin","command":["bash","-lc","ls"],"cwd":"/Users/test/project","duration":{"secs":0,"nanos":1},"exit_code":1,"formatted_output":"failed","parsed_cmd":[],"status":"failed","stderr":"permission denied","stdout":"","turn_id":"turn_1"}}
        """#
        let endResult = CodexEventMapper.parse(line: endLine, fileURL: fileURL, context: context)
        XCTAssertEqual(endResult.events.count, 1)
        let postTool = try XCTUnwrap(endResult.events.first)
        XCTAssertEqual(postTool.hookEventName, HookEventType.postToolUseFailure.rawValue)
        XCTAssertEqual(postTool.toolName, "exec_command")
        XCTAssertEqual(postTool.toolUseId, "call_exec_begin")
        XCTAssertEqual(postTool.toolResponse?["exit_code"]?.intValue, 1)
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

    func testContextCompactedEventMessageMapsToPreCompact() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let context = CodexSessionContext(
            sessionId: sessionId,
            cwd: "/Users/test/project",
            source: "cli",
            originator: "codex_cli_rs"
        )
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")
        let line = """
        {"type":"event_msg","payload":{"type":"context_compacted"}}
        """

        let result = CodexEventMapper.parse(line: line, fileURL: fileURL, context: context)

        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events.first?.hookEventName, HookEventType.preCompact.rawValue)
        XCTAssertEqual(result.events.first?.reason, "context_compacted")
    }

    func testItemCompletedMapsToTaskCompleted() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let context = CodexSessionContext(
            sessionId: sessionId,
            cwd: "/Users/test/project",
            source: "cli",
            originator: "codex_cli_rs"
        )
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")
        let line = #"""
        {"type":"event_msg","payload":{"type":"item_completed","turn_id":"turn_plan","item":{"type":"Plan","id":"plan_1","text":"# Do the thing\n\n- step"}}}
        """#

        let result = CodexEventMapper.parse(line: line, fileURL: fileURL, context: context)

        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events.first?.hookEventName, HookEventType.taskCompleted.rawValue)
        XCTAssertEqual(result.events.first?.taskId, "turn_plan")
        XCTAssertEqual(result.events.first?.taskSubject, "# Do the thing")
    }

    func testReviewModeEventsMapToConfigChange() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let context = CodexSessionContext(
            sessionId: sessionId,
            cwd: "/Users/test/project",
            source: "cli",
            originator: "codex_cli_rs"
        )
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")

        let enteredLine = #"""
        {"type":"event_msg","payload":{"type":"entered_review_mode","target":{"type":"uncommittedChanges"}}}
        """#
        let entered = CodexEventMapper.parse(line: enteredLine, fileURL: fileURL, context: context)
        XCTAssertEqual(entered.events.count, 1)
        XCTAssertEqual(entered.events.first?.hookEventName, HookEventType.configChange.rawValue)
        XCTAssertEqual(entered.events.first?.reason, "entered_review_mode")

        let exitedLine = #"""
        {"type":"event_msg","payload":{"type":"exited_review_mode","review_output":null}}
        """#
        let exited = CodexEventMapper.parse(line: exitedLine, fileURL: fileURL, context: context)
        XCTAssertEqual(exited.events.count, 1)
        XCTAssertEqual(exited.events.first?.hookEventName, HookEventType.configChange.rawValue)
        XCTAssertEqual(exited.events.first?.reason, "exited_review_mode")
    }

    func testAgentMessageAndReasoningEventMessagesMapToNotifications() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let context = CodexSessionContext(
            sessionId: sessionId,
            cwd: "/Users/test/project",
            source: "cli",
            originator: "codex_cli_rs"
        )
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")

        let agentMessageLine = #"""
        {"type":"event_msg","payload":{"type":"agent_message","message":"Implemented the fix."}}
        """#
        let agentMessage = CodexEventMapper.parse(line: agentMessageLine, fileURL: fileURL, context: context)
        XCTAssertEqual(agentMessage.events.count, 1)
        XCTAssertEqual(agentMessage.events.first?.hookEventName, HookEventType.notification.rawValue)
        XCTAssertEqual(agentMessage.events.first?.notificationType, "codex_agent_message")
        XCTAssertEqual(agentMessage.events.first?.message, "Implemented the fix.")

        let reasoningLine = #"""
        {"type":"event_msg","payload":{"type":"agent_reasoning","text":"Inspecting project structure"}}
        """#
        let reasoning = CodexEventMapper.parse(line: reasoningLine, fileURL: fileURL, context: context)
        XCTAssertEqual(reasoning.events.count, 1)
        XCTAssertEqual(reasoning.events.first?.hookEventName, HookEventType.notification.rawValue)
        XCTAssertEqual(reasoning.events.first?.notificationType, "codex_agent_reasoning")
        XCTAssertEqual(reasoning.events.first?.message, "Inspecting project structure")
    }

    func testCommentaryAgentQuestionSynthesizesAskUserQuestionPermissionRequest() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let context = CodexSessionContext(
            sessionId: sessionId,
            cwd: "/Users/test/project",
            source: "cli",
            originator: "codex_cli_rs"
        )
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")
        let line = #"""
        {"type":"event_msg","payload":{"type":"agent_message","phase":"commentary","message":"Which remote should I use for the dry-run push?"}}
        """#

        let result = CodexEventMapper.parse(line: line, fileURL: fileURL, context: context)

        XCTAssertEqual(result.events.count, 2)

        let notification = try XCTUnwrap(result.events.first)
        XCTAssertEqual(notification.hookEventName, HookEventType.notification.rawValue)
        XCTAssertEqual(notification.notificationType, "codex_agent_message")
        XCTAssertEqual(notification.message, "Which remote should I use for the dry-run push?")

        let permission = try XCTUnwrap(result.events.last)
        XCTAssertEqual(permission.hookEventName, HookEventType.permissionRequest.rawValue)
        XCTAssertEqual(permission.toolName, "AskUserQuestion")
        XCTAssertEqual(permission.message, "Which remote should I use for the dry-run push?")
        let questions = try XCTUnwrap(permission.toolInput?["questions"]?.value as? [[String: Any]])
        XCTAssertEqual(
            questions.first?["question"] as? String,
            "Which remote should I use for the dry-run push?"
        )
    }

    func testFinalAnswerAgentMessageWithEmptyTextIsIgnored() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let context = CodexSessionContext(
            sessionId: sessionId,
            cwd: "/Users/test/project",
            source: "cli",
            originator: "codex_cli_rs"
        )
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")
        let line = #"""
        {"type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","message":"   "}}
        """#

        let result = CodexEventMapper.parse(line: line, fileURL: fileURL, context: context)

        XCTAssertTrue(result.events.isEmpty)
    }

    func testTokenCountEventMessageMapsToNotification() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let context = CodexSessionContext(
            sessionId: sessionId,
            cwd: "/Users/test/project",
            source: "cli",
            originator: "codex_cli_rs"
        )
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")
        let line = #"""
        {"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":11.0},"secondary":{"used_percent":14.0}}}}
        """#

        let result = CodexEventMapper.parse(line: line, fileURL: fileURL, context: context)
        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events.first?.hookEventName, HookEventType.notification.rawValue)
        XCTAssertEqual(result.events.first?.notificationType, "codex_token_count")
        XCTAssertEqual(result.events.first?.message, "Token usage: primary 11%, secondary 14%")
    }

    func testTokenCountFallsBackToAbsoluteUsageWhenRateLimitsMissing() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let context = CodexSessionContext(
            sessionId: sessionId,
            cwd: "/Users/test/project",
            source: "cli",
            originator: "codex_cli_rs"
        )
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")
        let line = #"""
        {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":13500,"cached_input_tokens":3456,"output_tokens":848,"reasoning_output_tokens":793,"total_tokens":14348}},"rate_limits":null}}
        """#

        let result = CodexEventMapper.parse(line: line, fileURL: fileURL, context: context)

        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events.first?.hookEventName, HookEventType.notification.rawValue)
        XCTAssertEqual(result.events.first?.notificationType, "codex_token_count")
        XCTAssertEqual(
            result.events.first?.message,
            "Token usage: total 14,348, input 13,500 (+ 3,456 cached), output 848 (reasoning 793)"
        )
    }

    func testResponseItemMessageMapsToNotification() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let context = CodexSessionContext(
            sessionId: sessionId,
            cwd: "/Users/test/project",
            source: "cli",
            originator: "codex_cli_rs"
        )
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")
        let line = #"""
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done with implementation"}]}}
        """#

        let result = CodexEventMapper.parse(line: line, fileURL: fileURL, context: context)

        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events.first?.hookEventName, HookEventType.notification.rawValue)
        XCTAssertEqual(result.events.first?.notificationType, "codex_agent_message")
        XCTAssertEqual(result.events.first?.message, "Done with implementation")
    }

    func testResponseItemCommentaryAssistantMessageIsIgnoredToAvoidDuplicateNotification() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let context = CodexSessionContext(
            sessionId: sessionId,
            cwd: "/Users/test/project",
            source: "cli",
            originator: "codex_cli_rs"
        )
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")
        let line = #"""
        {"type":"response_item","payload":{"type":"message","role":"assistant","phase":"commentary","content":[{"type":"output_text","text":"Still working"}]}}
        """#

        let result = CodexEventMapper.parse(line: line, fileURL: fileURL, context: context)

        XCTAssertTrue(result.events.isEmpty)
    }

    func testResponseItemFinalAnswerAssistantMessageIsIgnoredToAvoidDuplicateNotification() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let context = CodexSessionContext(
            sessionId: sessionId,
            cwd: "/Users/test/project",
            source: "cli",
            originator: "codex_cli_rs"
        )
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")
        let line = #"""
        {"type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"Done"}]}}
        """#

        let result = CodexEventMapper.parse(line: line, fileURL: fileURL, context: context)

        XCTAssertTrue(result.events.isEmpty)
    }

    func testResponseItemUserMessageIsIgnoredToAvoidInstructionNoise() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let context = CodexSessionContext(
            sessionId: sessionId,
            cwd: "/Users/test/project",
            source: "cli",
            originator: "codex_cli_rs"
        )
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")
        let line = #"""
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"User prompt"}]}}
        """#

        let result = CodexEventMapper.parse(line: line, fileURL: fileURL, context: context)

        XCTAssertTrue(result.events.isEmpty)
    }

    func testResponseItemReasoningMapsToNotification() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let context = CodexSessionContext(
            sessionId: sessionId,
            cwd: "/Users/test/project",
            source: "cli",
            originator: "codex_cli_rs"
        )
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")
        let line = #"""
        {"type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"Inspecting test suite"}]}}
        """#

        let result = CodexEventMapper.parse(line: line, fileURL: fileURL, context: context)

        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events.first?.hookEventName, HookEventType.notification.rawValue)
        XCTAssertEqual(result.events.first?.notificationType, "codex_agent_reasoning")
        XCTAssertEqual(result.events.first?.message, "Inspecting test suite")
    }

    func testResponseItemWebSearchCallMapsToToolLifecycle() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let context = CodexSessionContext(
            sessionId: sessionId,
            cwd: "/Users/test/project",
            source: "cli",
            originator: "codex_cli_rs"
        )
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")
        let line = #"""
        {"type":"response_item","payload":{"type":"web_search_call","status":"completed","action":{"type":"search","query":"codex docs","queries":["codex docs"]}}}
        """#

        let result = CodexEventMapper.parse(line: line, fileURL: fileURL, context: context)

        XCTAssertEqual(result.events.count, 2)
        XCTAssertEqual(result.events.first?.hookEventName, HookEventType.preToolUse.rawValue)
        XCTAssertEqual(result.events.first?.toolName, "web_search_call")
        XCTAssertEqual(result.events.last?.hookEventName, HookEventType.postToolUse.rawValue)
        XCTAssertEqual(result.events.last?.toolName, "web_search_call")
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
        let outputResult = CodexEventMapper.parse(line: outputLine, fileURL: fileURL, context: callResult.context ?? context)
        XCTAssertEqual(outputResult.events.count, 1)
        let postTool = try XCTUnwrap(outputResult.events.first)
        XCTAssertEqual(postTool.hookEventName, HookEventType.postToolUse.rawValue)
        XCTAssertEqual(postTool.toolName, "exec_command")
        XCTAssertEqual(postTool.toolUseId, "call_abc")
        XCTAssertEqual(postTool.toolResponse?["exit_code"]?.intValue, 0)
    }

    func testCustomToolCallReadsInputFieldAndSynthesizesPermissionRequest() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let context = CodexSessionContext(
            sessionId: sessionId,
            cwd: "/Users/test/project",
            source: "cli",
            originator: "codex_cli_rs"
        )
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")
        let line = #"""
        {"type":"response_item","payload":{"type":"custom_tool_call","name":"exec_command","call_id":"call_custom_perm","input":"{\"cmd\":\"git push\",\"sandbox_permissions\":\"require_escalated\",\"justification\":\"Need network access to push\"}"}}
        """#

        let result = CodexEventMapper.parse(line: line, fileURL: fileURL, context: context)

        XCTAssertEqual(result.events.count, 2)
        let preTool = try XCTUnwrap(result.events.first)
        XCTAssertEqual(preTool.hookEventName, HookEventType.preToolUse.rawValue)
        XCTAssertEqual(preTool.toolUseId, "call_custom_perm")
        XCTAssertEqual(preTool.toolInput?["cmd"]?.stringValue, "git push")
        XCTAssertEqual(preTool.toolInput?["sandbox_permissions"]?.stringValue, "require_escalated")

        let permission = try XCTUnwrap(result.events.last)
        XCTAssertEqual(permission.hookEventName, HookEventType.permissionRequest.rawValue)
        XCTAssertEqual(permission.toolUseId, "call_custom_perm")
        XCTAssertEqual(permission.message, "Need network access to push")
    }

    func testFunctionCallOutputDetectsFailureFromExitCodeTextWithoutStatus() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let context = CodexSessionContext(
            sessionId: sessionId,
            cwd: "/Users/test/project",
            source: "cli",
            originator: "codex_cli_rs"
        )
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")
        let line = #"""
        {"type":"response_item","payload":{"type":"function_call_output","call_id":"call_fail_text","output":"Exit code: 1\nWall time: 0.1 seconds\nOutput:\npermission denied"}}
        """#

        let result = CodexEventMapper.parse(line: line, fileURL: fileURL, context: context)

        XCTAssertEqual(result.events.count, 1)
        let postTool = try XCTUnwrap(result.events.first)
        XCTAssertEqual(postTool.hookEventName, HookEventType.postToolUseFailure.rawValue)
        XCTAssertEqual(postTool.toolUseId, "call_fail_text")
        XCTAssertEqual(postTool.toolResponse?["exit_code"]?.intValue, 1)
        XCTAssertEqual(postTool.toolResponse?["output"]?.stringValue, "Exit code: 1\nWall time: 0.1 seconds\nOutput:\npermission denied")
    }

    func testCustomToolCallOutputDetectsFailureFromErrorPayloadWithoutStatus() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let context = CodexSessionContext(
            sessionId: sessionId,
            cwd: "/Users/test/project",
            source: "cli",
            originator: "codex_cli_rs"
        )
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")
        let line = #"""
        {"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call_custom_fail","output":"{\"error\":\"tool crashed\"}"}}
        """#

        let result = CodexEventMapper.parse(line: line, fileURL: fileURL, context: context)

        XCTAssertEqual(result.events.count, 1)
        let postTool = try XCTUnwrap(result.events.first)
        XCTAssertEqual(postTool.hookEventName, HookEventType.postToolUseFailure.rawValue)
        XCTAssertEqual(postTool.toolUseId, "call_custom_fail")
        XCTAssertEqual(postTool.toolResponse?["error"]?.stringValue, "tool crashed")
    }

    func testCustomToolCallOutputDetectsFailureFromMetadataExitCodeAndPreservesToolName() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let context = CodexSessionContext(
            sessionId: sessionId,
            cwd: "/Users/test/project",
            source: "cli",
            originator: "codex_cli_rs",
            toolNamesByCallId: ["call_custom_apply_patch": "apply_patch"]
        )
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")
        let line = #"""
        {"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call_custom_apply_patch","output":"{\"output\":\"patch failed\",\"metadata\":{\"exit_code\":1,\"duration_seconds\":0.1}}"}}
        """#

        let result = CodexEventMapper.parse(line: line, fileURL: fileURL, context: context)

        XCTAssertEqual(result.events.count, 1)
        let postTool = try XCTUnwrap(result.events.first)
        XCTAssertEqual(postTool.hookEventName, HookEventType.postToolUseFailure.rawValue)
        XCTAssertEqual(postTool.toolName, "apply_patch")
        XCTAssertEqual(postTool.toolUseId, "call_custom_apply_patch")
        let metadata = try XCTUnwrap(postTool.toolResponse?["metadata"]?.value as? [String: Any])
        XCTAssertEqual(metadata["exit_code"] as? Int, 1)
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

    func testFunctionCallPermissionRequestIncludesPrefixRuleSuggestion() throws {
        let sessionId = "019cd686-3b91-78a1-9356-21b475548352"
        let context = CodexSessionContext(
            sessionId: sessionId,
            cwd: "/Users/test/project",
            source: "cli",
            originator: "codex_cli_rs"
        )
        let fileURL = URL(fileURLWithPath: "/tmp/rollout-2026-03-09T23-54-07-\(sessionId).jsonl")
        let line = #"""
        {"type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call_perm_rule","arguments":"{\"cmd\":\"git push\",\"sandbox_permissions\":\"require_escalated\",\"justification\":\"Need network access to push branch\",\"prefix_rule\":[\"git\",\"push\"]}"}}
        """#

        let result = CodexEventMapper.parse(line: line, fileURL: fileURL, context: context)

        let permission = try XCTUnwrap(result.events.last)
        let suggestions = try XCTUnwrap(permission.permissionSuggestions?.compactMap { $0.value as? [String: Any] })
        XCTAssertEqual(suggestions.count, 1)
        let rules = try XCTUnwrap(suggestions.first?["rules"] as? [[String: String]])
        XCTAssertEqual(rules.first?["toolName"], "exec_command")
        XCTAssertEqual(rules.first?["ruleContent"], "git push")
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

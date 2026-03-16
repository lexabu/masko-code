import XCTest
@testable import masko_code

final class CodexAppServerClientTests: XCTestCase {
    func testMapCommandApprovalRequestToPermissionEvent() throws {
        let params: [String: Any] = [
            "threadId": "thr_1",
            "turnId": "turn_1",
            "itemId": "item_1",
            "command": "git push",
            "cwd": "/Users/test/project",
            "reason": "Needs network",
            "proposedExecpolicyAmendment": ["git push"],
        ]

        let mapped = CodexAppServerClient.mapServerRequest(
            method: "item/commandExecution/requestApproval",
            params: params,
            requestId: "42",
            rawId: 42
        )

        XCTAssertNotNil(mapped)
        let event = try XCTUnwrap(mapped?.event)
        XCTAssertEqual(event.hookEventName, HookEventType.permissionRequest.rawValue)
        XCTAssertEqual(event.source, "codex-app-server")
        XCTAssertEqual(event.sessionId, "thr_1")
        XCTAssertEqual(event.taskId, "turn_1")
        XCTAssertEqual(event.toolUseId, "42")
        XCTAssertEqual(event.toolName, "exec_command")
        XCTAssertEqual(event.toolInput?["cmd"]?.stringValue, "git push")
        XCTAssertEqual(event.toolInput?["sandbox_permissions"]?.stringValue, "require_escalated")
        XCTAssertEqual(event.toolInput?["codex_app_server_request_id"]?.stringValue, "42")
        XCTAssertEqual(event.toolInput?["codex_app_server_item_id"]?.stringValue, "item_1")
        XCTAssertEqual(event.message, "Needs network")
        XCTAssertEqual(event.permissionSuggestions?.count, 1)
    }

    func testMapLegacyExecApprovalUsesConversationAndApprovalIdentifiers() throws {
        let params: [String: Any] = [
            "conversationId": "conv_legacy",
            "callId": "call_legacy",
            "approvalId": "approval_legacy",
            "command": ["git", "push"],
            "cwd": "/Users/test/project",
        ]

        let mapped = CodexAppServerClient.mapServerRequest(
            method: "execCommandApproval",
            params: params,
            requestId: "req_legacy",
            rawId: "req_legacy"
        )

        XCTAssertNotNil(mapped)
        let event = try XCTUnwrap(mapped?.event)
        XCTAssertEqual(event.sessionId, "conv_legacy")
        XCTAssertEqual(event.toolUseId, "req_legacy")
        XCTAssertEqual(event.toolInput?["codex_app_server_approval_id"]?.stringValue, "approval_legacy")
        XCTAssertEqual(event.toolInput?["callId"]?.stringValue, "call_legacy")
    }

    func testMapQuestionRequestToAskUserQuestionEvent() throws {
        let params: [String: Any] = [
            "threadId": "thr_q",
            "turnId": "turn_q",
            "itemId": "item_q",
            "questions": [
                [
                    "id": "q1",
                    "header": "Decision",
                    "question": "Pick one",
                    "options": [
                        ["label": "A", "description": "first"],
                    ],
                ],
            ],
        ]

        let mapped = CodexAppServerClient.mapServerRequest(
            method: "item/tool/requestUserInput",
            params: params,
            requestId: "99",
            rawId: "99"
        )

        XCTAssertNotNil(mapped)
        let event = try XCTUnwrap(mapped?.event)
        XCTAssertEqual(event.toolName, "AskUserQuestion")
        XCTAssertEqual(event.message, "Pick one")
        XCTAssertNotNil(event.toolInput?["questions"])
        XCTAssertEqual(mapped?.pending.questions.count, 1)
        XCTAssertEqual(mapped?.pending.questions.first?.id, "q1")
    }

    func testMapTurnCompletedNotificationEmitsStopAndTaskCompleted() {
        let params: [String: Any] = [
            "threadId": "thr_done",
            "turn": [
                "id": "turn_done",
                "status": "completed",
                "items": [],
            ],
        ]

        let events = CodexAppServerClient.mapServerNotification(method: "turn/completed", params: params)

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].hookEventName, HookEventType.stop.rawValue)
        XCTAssertEqual(events[0].reason, "completed")
        XCTAssertEqual(events[1].hookEventName, HookEventType.taskCompleted.rawValue)
        XCTAssertEqual(events[1].taskId, "turn_done")
    }

    func testMapTurnCompletedNotificationForFailedTurnUsesFailedReason() {
        let params: [String: Any] = [
            "threadId": "thr_failed",
            "turn": [
                "id": "turn_failed",
                "status": "failed",
                "items": [],
            ],
        ]

        let events = CodexAppServerClient.mapServerNotification(method: "turn/completed", params: params)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].hookEventName, HookEventType.stop.rawValue)
        XCTAssertEqual(events[0].reason, "failed")
    }

    func testMapAgentDeltaNotificationEmitsCodexMessageNotification() {
        let params: [String: Any] = [
            "threadId": "thr_delta",
            "itemId": "item_delta",
            "turnId": "turn_delta",
            "delta": "hello",
        ]

        let events = CodexAppServerClient.mapServerNotification(method: "item/agentMessage/delta", params: params)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].hookEventName, HookEventType.notification.rawValue)
        XCTAssertEqual(events[0].notificationType, "codex_agent_message")
        XCTAssertEqual(events[0].message, "hello")
    }

    func testMapServerRequestResolvedNotificationDismissesPendingByRequestId() {
        let params: [String: Any] = [
            "threadId": "thr_pending",
            "requestId": 321,
        ]

        let events = CodexAppServerClient.mapServerNotification(method: "serverRequest/resolved", params: params)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].hookEventName, HookEventType.postToolUse.rawValue)
        XCTAssertEqual(events[0].toolUseId, "321")
        XCTAssertEqual(events[0].sessionId, "thr_pending")
    }

    func testMapItemStartedCommandExecutionToPreToolUse() {
        let params: [String: Any] = [
            "threadId": "thr_tool",
            "turnId": "turn_tool",
            "item": [
                "id": "item_cmd_1",
                "type": "commandExecution",
                "status": "inProgress",
                "command": "ls -la",
                "cwd": "/Users/test/project",
            ],
        ]

        let events = CodexAppServerClient.mapServerNotification(method: "item/started", params: params)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].hookEventName, HookEventType.preToolUse.rawValue)
        XCTAssertEqual(events[0].toolName, "exec_command")
        XCTAssertEqual(events[0].toolUseId, "item_cmd_1")
        XCTAssertEqual(events[0].toolInput?["cmd"]?.stringValue, "ls -la")
    }

    func testMapItemCompletedFailedCommandExecutionToPostToolUseFailure() {
        let params: [String: Any] = [
            "threadId": "thr_tool",
            "turnId": "turn_tool",
            "item": [
                "id": "item_cmd_2",
                "type": "commandExecution",
                "status": "failed",
                "command": "git push",
                "cwd": "/Users/test/project",
                "aggregatedOutput": "fatal: network unreachable",
                "exitCode": 1,
            ],
        ]

        let events = CodexAppServerClient.mapServerNotification(method: "item/completed", params: params)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].hookEventName, HookEventType.postToolUseFailure.rawValue)
        XCTAssertEqual(events[0].toolName, "exec_command")
        XCTAssertEqual(events[0].toolUseId, "item_cmd_2")
        XCTAssertEqual(events[0].message, "fatal: network unreachable")
    }
}

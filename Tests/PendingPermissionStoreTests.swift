import Foundation
import XCTest
@testable import masko_code

final class PendingPermissionStoreTests: XCTestCase {
    func testAddLocalAndResolveAllowInvokesDecisionHandler() throws {
        let store = PendingPermissionStore()
        defer { store.stopTimers() }

        var handledDecisions: [PermissionDecision] = []
        let event = makeCodexPermissionEvent(toolUseId: "call_1", cmd: "git push")

        store.addLocal(event: event) { resolution in
            guard case .decision(let decision) = resolution else { return false }
            handledDecisions.append(decision)
            return true
        }

        XCTAssertEqual(store.pending.count, 1)
        let id = try XCTUnwrap(store.pending.first?.id)
        store.resolve(id: id, decision: .allow)

        XCTAssertEqual(handledDecisions, [.allow])
        XCTAssertEqual(store.pending.count, 0)
    }

    func testLocalDecisionFailureKeepsPermissionPending() throws {
        let store = PendingPermissionStore()
        defer { store.stopTimers() }

        let event = makeCodexPermissionEvent(toolUseId: "call_2", cmd: "git push")
        store.addLocal(event: event) { _ in false }
        let id = try XCTUnwrap(store.pending.first?.id)

        store.resolve(id: id, decision: .deny)

        XCTAssertEqual(store.pending.count, 1)
    }

    func testAddLocalSkipsDuplicateToolUseId() {
        let store = PendingPermissionStore()
        defer { store.stopTimers() }

        let first = makeCodexPermissionEvent(toolUseId: "call_dup", cmd: "git push")
        let second = makeCodexPermissionEvent(toolUseId: "call_dup", cmd: "git pull")

        store.addLocal(event: first) { _ in true }
        store.addLocal(event: second) { _ in true }

        XCTAssertEqual(store.pending.count, 1)
        XCTAssertEqual(store.pending.first?.event.toolInput?["cmd"]?.stringValue, "git push")
    }

    func testResolveWithAnswersUsesLocalResolutionHandler() throws {
        let store = PendingPermissionStore()
        defer { store.stopTimers() }

        var handled = false
        let event = makeCodexPermissionEvent(toolUseId: "call_3", cmd: "scripts/codex-mascot-smoke.sh")
        store.addLocal(event: event) { resolution in
            if case .answers(let answers) = resolution {
                handled = answers["q1"] == "yes"
                return true
            }
            return false
        }
        let id = try XCTUnwrap(store.pending.first?.id)

        store.resolveWithAnswers(id: id, answers: ["q1": "yes"])

        XCTAssertTrue(handled)
        XCTAssertEqual(store.pending.count, 0)
    }

    func testResolveWithFeedbackUsesLocalResolutionHandler() throws {
        let store = PendingPermissionStore()
        defer { store.stopTimers() }

        var handled = false
        let event = makeCodexPermissionEvent(toolUseId: "call_4", cmd: "update plan")
        store.addLocal(event: event) { resolution in
            if case .feedback(let feedback) = resolution {
                handled = feedback == "Please trim this down."
                return true
            }
            return false
        }
        let id = try XCTUnwrap(store.pending.first?.id)

        store.resolveWithFeedback(id: id, feedback: "Please trim this down.")

        XCTAssertTrue(handled)
        XCTAssertEqual(store.pending.count, 0)
    }

    func testResolveWithPermissionsUsesLocalResolutionHandler() throws {
        let store = PendingPermissionStore()
        defer { store.stopTimers() }

        var handled = false
        let event = makeCodexPermissionEvent(toolUseId: "call_5", cmd: "git push")
        store.addLocal(event: event) { resolution in
            if case .permissionSuggestions(let suggestions) = resolution {
                handled = suggestions.count == 1 && suggestions.first?.type == "setMode"
                return true
            }
            return false
        }
        let id = try XCTUnwrap(store.pending.first?.id)

        let suggestions = [
            PermissionSuggestion(type: "setMode", destination: "session", behavior: nil, rules: nil, mode: "acceptEdits"),
        ]
        store.resolveWithPermissions(id: id, suggestions: suggestions)

        XCTAssertTrue(handled)
        XCTAssertEqual(store.pending.count, 0)
    }

    private func makeCodexPermissionEvent(toolUseId: String, cmd: String) -> ClaudeEvent {
        ClaudeEvent(
            hookEventName: HookEventType.permissionRequest.rawValue,
            sessionId: "session-test",
            cwd: "/tmp/project",
            toolName: "exec_command",
            toolInput: [
                "cmd": AnyCodable(cmd),
                "sandbox_permissions": AnyCodable("require_escalated"),
            ],
            toolUseId: toolUseId,
            source: "codex-cli"
        )
    }
}

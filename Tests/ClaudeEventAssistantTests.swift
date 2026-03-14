import XCTest
@testable import masko_code

final class ClaudeEventAssistantTests: XCTestCase {
    func testAssistantDisplayNameDefaultsToClaude() {
        let event = ClaudeEvent(hookEventName: HookEventType.sessionStart.rawValue)
        XCTAssertEqual(event.assistantDisplayName, "Claude Code")
    }

    func testAssistantDisplayNameDetectsCodexCLI() {
        let event = ClaudeEvent(
            hookEventName: HookEventType.sessionStart.rawValue,
            source: "codex-cli"
        )
        XCTAssertEqual(event.assistantDisplayName, "Codex")
    }

    func testAssistantDisplayNameDetectsCodexDesktop() {
        let event = ClaudeEvent(
            hookEventName: HookEventType.sessionStart.rawValue,
            source: "vscode"
        )
        XCTAssertEqual(event.assistantDisplayName, "Codex")
    }
}

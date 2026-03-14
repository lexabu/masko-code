import XCTest
@testable import masko_code

final class SessionStoreProcessMatchersTests: XCTestCase {
    func testAssistantProcessMatchersCoverClaudeCodexCLIAndCodexDesktopApp() {
        let matchers = SessionStore.assistantProcessMatchers

        XCTAssertTrue(matchers.contains { $0 == ["-x", "claude"] })
        XCTAssertTrue(matchers.contains { $0 == ["-x", "codex"] })
        XCTAssertTrue(matchers.contains { $0 == ["-f", "Codex.app"] })
    }
}

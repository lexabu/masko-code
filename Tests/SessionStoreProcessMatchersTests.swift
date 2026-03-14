import XCTest
@testable import masko_code

final class SessionStoreProcessMatchersTests: XCTestCase {
    func testAssistantProcessMatchersCoverClaudeAndCodexVariants() {
        let matchers = SessionStore.assistantProcessMatchers

        XCTAssertTrue(matchers.contains { $0 == ["-x", "claude"] })
        XCTAssertTrue(matchers.contains { $0 == ["-x", "codex"] })
        XCTAssertTrue(matchers.contains { $0 == ["-x", "Codex"] })
        XCTAssertTrue(matchers.contains { $0 == ["-f", "codex_cli_rs"] })
        XCTAssertTrue(matchers.contains { $0 == ["-f", "Codex.app"] })
        XCTAssertTrue(matchers.contains { $0 == ["-f", "Codex Desktop"] })
    }
}

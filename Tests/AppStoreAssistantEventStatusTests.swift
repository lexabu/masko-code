import XCTest
@testable import masko_code

final class AppStoreAssistantEventStatusTests: XCTestCase {
    func testStatusWhenBothClaudeAndCodexIngestionAreActive() {
        let status = AppStore.assistantEventIngestionStatus(
            localServerRunning: true,
            localServerPort: 49152,
            codexMonitorRunning: true
        )
        XCTAssertTrue(status.isActive)
        XCTAssertEqual(status.text, "Listening on 49152 + Codex logs")
    }

    func testStatusWhenOnlyClaudeHookServerIsActive() {
        let status = AppStore.assistantEventIngestionStatus(
            localServerRunning: true,
            localServerPort: 49152,
            codexMonitorRunning: false
        )
        XCTAssertTrue(status.isActive)
        XCTAssertEqual(status.text, "Listening on 49152")
    }

    func testStatusWhenOnlyCodexLogMonitorIsActive() {
        let status = AppStore.assistantEventIngestionStatus(
            localServerRunning: false,
            localServerPort: 49152,
            codexMonitorRunning: true
        )
        XCTAssertTrue(status.isActive)
        XCTAssertEqual(status.text, "Listening to Codex logs")
    }

    func testStatusWhenNoIngestionIsActive() {
        let status = AppStore.assistantEventIngestionStatus(
            localServerRunning: false,
            localServerPort: 49152,
            codexMonitorRunning: false
        )
        XCTAssertFalse(status.isActive)
        XCTAssertEqual(status.text, "Offline")
    }
}

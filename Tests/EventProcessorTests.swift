import XCTest
@testable import masko_code

@MainActor
final class EventProcessorTests: XCTestCase {
    func testCodexPermissionNotificationUsesEventMessage() async throws {
        let eventStore = EventStore()
        eventStore.clear()
        let sessionStore = SessionStore()
        defer { sessionStore.stopTimers() }
        let notificationStore = NotificationStore()
        let processor = EventProcessor(
            eventStore: eventStore,
            sessionStore: sessionStore,
            notificationStore: notificationStore,
            notificationService: .shared
        )

        let sessionId = "event-processor-codex-permission"
        let event = ClaudeEvent(
            hookEventName: HookEventType.permissionRequest.rawValue,
            sessionId: sessionId,
            cwd: "/tmp/project",
            toolName: "exec_command",
            message: "Need network access to push",
            source: "codex-cli"
        )

        await processor.process(event)

        let notification = try XCTUnwrap(notificationStore.notifications.first(where: { $0.sessionId == sessionId }))
        XCTAssertEqual(notification.title, "Permission Requested")
        XCTAssertEqual(notification.body, "Need network access to push")
    }

    func testClaudePermissionNotificationKeepsGenericBody() async throws {
        let eventStore = EventStore()
        eventStore.clear()
        let sessionStore = SessionStore()
        defer { sessionStore.stopTimers() }
        let notificationStore = NotificationStore()
        let processor = EventProcessor(
            eventStore: eventStore,
            sessionStore: sessionStore,
            notificationStore: notificationStore,
            notificationService: .shared
        )

        let sessionId = "event-processor-claude-permission"
        let event = ClaudeEvent(
            hookEventName: HookEventType.permissionRequest.rawValue,
            sessionId: sessionId,
            cwd: "/tmp/project",
            toolName: "Bash",
            message: "This Claude message should not override the standard body",
            source: "claude"
        )

        await processor.process(event)

        let notification = try XCTUnwrap(notificationStore.notifications.first(where: { $0.sessionId == sessionId }))
        XCTAssertEqual(notification.title, "Permission Requested")
        XCTAssertEqual(notification.body, "Claude Code wants to use Bash in project")
    }
}

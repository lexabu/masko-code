import Foundation

/// Copilot CLI adapter - manages plugin installation.
/// Copilot events arrive at the shared /hook endpoint (same LocalServer as Claude Code)
/// with `source: "copilot"` injected by copilot-hook.sh. No separate server needed.
final class CopilotAdapter: AgentAdapter {
    let source: AgentSource = .copilot

    /// Copilot events flow through ClaudeCodeAdapter's LocalServer,
    /// so this adapter doesn't run its own server.
    var isRunning: Bool { CopilotCLIInstaller.isRegistered() }

    // Callbacks are unused - events arrive through the shared LocalServer
    var onEvent: ((AgentEvent) -> Void)?
    var onPermissionRequest: ((AgentEvent, ResponseTransport) -> Void)?
    var onInput: ((String, ConditionValue) -> Void)?

    func isAvailable() -> Bool {
        CopilotCLIInstaller.isCopilotAvailable()
    }

    func isRegistered() -> Bool {
        CopilotCLIInstaller.isRegistered()
    }

    func install() throws {
        try CopilotCLIInstaller.install()
    }

    func uninstall() {
        CopilotCLIInstaller.uninstall()
    }

    func start() throws {
        // Keep hook script in sync (version check skips if current)
        if CopilotCLIInstaller.isRegistered() {
            try? CopilotCLIInstaller.ensureCopilotHookScript()
        }
    }

    func stop() {
        // Nothing to stop - no own server
    }
}

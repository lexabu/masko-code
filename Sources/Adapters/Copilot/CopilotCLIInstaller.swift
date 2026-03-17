import Foundation

/// Manages GitHub Copilot CLI plugin registration.
/// Installs a plugin that forwards Copilot hook events to Masko's local server.
enum CopilotCLIInstaller {

    // MARK: - Constants

    private static let pluginDir = NSHomeDirectory() + "/.masko-desktop/copilot-plugin"
    private static let installedPluginsDir = NSHomeDirectory() + "/.copilot/installed-plugins/local/masko-copilot"
    private static let directPluginsDir = NSHomeDirectory() + "/.copilot/installed-plugins/_direct/copilot-plugin"
    private static let copilotHookScript = NSHomeDirectory() + "/.masko-desktop/hooks/copilot-hook.sh"
    private static let copilotHookCommand = "~/.masko-desktop/hooks/copilot-hook.sh"

    /// Copilot CLI hook events (subset of Claude Code events that Copilot supports)
    private static let hookEvents = [
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "ErrorOccurred",
    ]

    // MARK: - Public API

    /// Check if the Copilot CLI binary is available
    static func isCopilotAvailable() -> Bool {
        let paths = ["/usr/local/bin/copilot", "/opt/homebrew/bin/copilot"]
        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) { return true }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["copilot"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Check if our plugin is installed
    static func isRegistered() -> Bool {
        FileManager.default.fileExists(atPath: installedPluginsDir + "/plugin.json")
            || FileManager.default.fileExists(atPath: directPluginsDir + "/plugin.json")
    }

    /// Install the Copilot CLI plugin
    static func install() throws {
        try ensureCopilotHookScript()

        let fm = FileManager.default

        // Create plugin directory
        try fm.createDirectory(atPath: pluginDir, withIntermediateDirectories: true)

        // Write plugin.json
        let pluginManifest: [String: Any] = [
            "name": "masko-copilot",
            "description": "Masko Code companion for GitHub Copilot CLI",
            "version": "1.0.0",
            "author": ["name": "Masko"],
            "license": "MIT",
            "hooks": "hooks.json",
        ]
        let pluginData = try JSONSerialization.data(withJSONObject: pluginManifest, options: [.prettyPrinted, .sortedKeys])
        try pluginData.write(to: URL(fileURLWithPath: pluginDir + "/plugin.json"))

        // Write hooks.json - Copilot CLI uses { version: 1, hooks: { camelCase: [...] } }
        var hooksByEvent: [String: Any] = [:]
        for event in hookEvents {
            let camelEvent = toCamelCase(event)
            hooksByEvent[camelEvent] = [[
                "type": "command",
                "bash": "\(copilotHookCommand) \(event)",
            ]]
        }
        let hooksConfig: [String: Any] = [
            "version": 1,
            "hooks": hooksByEvent,
        ]
        let hooksData = try JSONSerialization.data(withJSONObject: hooksConfig, options: [.prettyPrinted, .sortedKeys])
        try hooksData.write(to: URL(fileURLWithPath: pluginDir + "/hooks.json"))

        // Try to install via copilot CLI
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "copilot plugin install \(pluginDir)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        // If CLI install failed, copy directly to the fallback plugins dir
        if process.terminationStatus != 0 {
            let destDir = directPluginsDir
            try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
            let pluginSrc = pluginDir + "/plugin.json"
            let hooksSrc = pluginDir + "/hooks.json"
            let pluginDst = destDir + "/plugin.json"
            let hooksDst = destDir + "/hooks.json"
            try? fm.removeItem(atPath: pluginDst)
            try? fm.removeItem(atPath: hooksDst)
            try fm.copyItem(atPath: pluginSrc, toPath: pluginDst)
            try fm.copyItem(atPath: hooksSrc, toPath: hooksDst)
        }
    }

    /// Uninstall the Copilot CLI plugin
    static func uninstall() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "copilot plugin uninstall masko-copilot"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()

        try? FileManager.default.removeItem(atPath: installedPluginsDir)
        try? FileManager.default.removeItem(atPath: directPluginsDir)
        try? FileManager.default.removeItem(atPath: pluginDir)
        try? FileManager.default.removeItem(atPath: copilotHookScript)
    }

    // MARK: - Hook Script

    private static let copilotScriptVersion = "# version: 1"

    /// Ensure the copilot hook script exists and is up to date.
    /// Called on app startup when the plugin is registered.
    static func ensureCopilotHookScript() throws {
        if FileManager.default.fileExists(atPath: copilotHookScript),
           let contents = try? String(contentsOfFile: copilotHookScript, encoding: .utf8),
           contents.contains(copilotScriptVersion) {
            return
        }

        let port = Constants.serverPort

        let script = """
        #!/bin/bash
        \(copilotScriptVersion)
        # copilot-hook.sh - Translates Copilot CLI hook events for Masko
        # Copilot CLI uses camelCase fields and doesn't include hook_event_name,
        # so we inject the event type (passed as $1) and remap field names.
        EVENT_TYPE="$1"
        INPUT=$(cat 2>/dev/null || echo '{}')

        # Exit early if Masko server isn't running
        curl -s --connect-timeout 0.3 "http://localhost:\(port)/health" >/dev/null 2>&1 || exit 0

        # Inject hook_event_name, source tag, and translate camelCase to snake_case
        INPUT=$(echo "$INPUT" | sed \\
            -e "s/^{/{\\\"hook_event_name\\\":\\\"$EVENT_TYPE\\\",\\\"source\\\":\\\"copilot\\\",/" \\
            -e 's/"sessionId"/"session_id"/g' \\
            -e 's/"toolName"/"tool_name"/g' \\
            -e 's/"toolArgs"/"tool_input"/g' \\
            -e 's/"toolResult"/"tool_response"/g' \\
            -e 's/"hookEventName"/"hook_event_name"/g' \\
            -e 's/"transcriptPath"/"transcript_path"/g' \\
            -e 's/"permissionMode"/"permission_mode"/g' \\
            -e 's/"toolUseId"/"tool_use_id"/g' \\
            -e 's/"notificationType"/"notification_type"/g' \\
            -e 's/"stopHookActive"/"stop_hook_active"/g' \\
            -e 's/"lastAssistantMessage"/"last_assistant_message"/g' \\
            -e 's/"agentId"/"agent_id"/g' \\
            -e 's/"agentType"/"agent_type"/g' \\
            -e 's/"taskId"/"task_id"/g' \\
            -e 's/"taskSubject"/"task_subject"/g')

        # Fire-and-forget
        curl -s -X POST -H "Content-Type: application/json" -d "$INPUT" \\
            "http://localhost:\(port)/hook" \\
            --connect-timeout 1 --max-time 2 2>/dev/null || true
        exit 0
        """

        let dir = (copilotHookScript as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try script.write(toFile: copilotHookScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: copilotHookScript
        )
    }

    // MARK: - Private

    /// Convert PascalCase to camelCase (e.g. "PreToolUse" -> "preToolUse")
    private static func toCamelCase(_ pascal: String) -> String {
        guard let first = pascal.first else { return pascal }
        return first.lowercased() + pascal.dropFirst()
    }
}

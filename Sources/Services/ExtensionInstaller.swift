import AppKit
import Foundation

/// Manages VS Code/Cursor/JetBrains extension installation for IDE terminal switching
enum ExtensionInstaller {

    // MARK: - Constants

    private static let extensionId = "masko.masko-terminal-focus"
    private static let jetbrainsPluginId = "ai.masko.terminal-focus"

    /// VS Code-family IDEs: (bundleId, CLI command, URI scheme, common CLI paths, skipAutoInstall)
    private static let vscodeConfigs: [(bundleId: String, command: String, scheme: String, paths: [String], skipAutoInstall: Bool)] = [
        (
            "com.todesktop.230313mzl4w4u92",
            "cursor",
            "cursor",
            [
                "/usr/local/bin/cursor",
                "/Applications/Cursor.app/Contents/Resources/app/bin/cursor",
            ],
            false
        ),
        (
            "com.microsoft.VSCode",
            "code",
            "vscode",
            [
                "/usr/local/bin/code",
                "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
            ],
            false
        ),
        (
            "com.microsoft.VSCodeInsiders",
            "code-insiders",
            "vscode-insiders",
            [
                "/usr/local/bin/code-insiders",
                "/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code-insiders",
            ],
            false
        ),
        (
            "com.exafunction.windsurf",
            "windsurf",
            "windsurf",
            [
                "/usr/local/bin/windsurf",
                "/Applications/Windsurf.app/Contents/Resources/app/bin/windsurf",
            ],
            false
        ),
        (
            // Antigravity's extension host crashes (SIGABRT) during module resolution.
            // Skip auto-install, but keep it available for manual install from Settings.
            "com.google.antigravity",
            "antigravity",
            "antigravity",
            [
                "/usr/local/bin/antigravity",
                "/Applications/Antigravity.app/Contents/Resources/app/bin/antigravity",
            ],
            true
        ),
    ]

    /// JetBrains IDEs: (bundleId, display name, URI scheme, app path for detection)
    private static let jetbrainsConfigs: [(bundleId: String, name: String, scheme: String, appPath: String)] = [
        ("com.jetbrains.pycharm", "PyCharm", "pycharm", "/Applications/PyCharm.app"),
        ("com.jetbrains.pycharm.ce", "PyCharm CE", "pycharm", "/Applications/PyCharm CE.app"),
        ("com.jetbrains.intellij", "IntelliJ IDEA", "idea", "/Applications/IntelliJ IDEA.app"),
        ("com.jetbrains.intellij.ce", "IntelliJ IDEA CE", "idea", "/Applications/IntelliJ IDEA CE.app"),
        ("com.jetbrains.WebStorm", "WebStorm", "webstorm", "/Applications/WebStorm.app"),
        ("com.jetbrains.goland", "GoLand", "goland", "/Applications/GoLand.app"),
        ("com.jetbrains.CLion", "CLion", "clion", "/Applications/CLion.app"),
        ("com.jetbrains.PhpStorm", "PhpStorm", "phpstorm", "/Applications/PhpStorm.app"),
        ("com.jetbrains.rubymine", "RubyMine", "rubymine", "/Applications/RubyMine.app"),
        ("com.jetbrains.rider", "Rider", "rider", "/Applications/Rider.app"),
    ]

    // MARK: - IDE Status

    struct IDEStatus: Identifiable {
        let name: String
        let command: String
        let isDetected: Bool
        let isInstalled: Bool
        var id: String { command }
    }

    /// Returns per-IDE detection and installation status for all supported IDEs.
    static func allIDEStatuses() -> [IDEStatus] {
        var statuses = vscodeConfigs.map { ide -> IDEStatus in
            let cliPath = resolveCommand(ide)
            let detected = cliPath != nil
            let installed = detected && extensionInstalled(cliPath: cliPath!)
            return IDEStatus(
                name: ideName(for: ide.command),
                command: ide.command,
                isDetected: detected,
                isInstalled: installed
            )
        }
        // JetBrains IDEs
        statuses += jetbrainsConfigs.compactMap { jb in
            let detected = FileManager.default.fileExists(atPath: jb.appPath)
            guard detected else { return nil }
            let installed = jetbrainsPluginInstalled(bundleId: jb.bundleId)
            return IDEStatus(
                name: jb.name,
                command: jb.scheme,  // Use scheme as the command identifier
                isDetected: true,
                isInstalled: installed
            )
        }
        return statuses
    }

    // MARK: - Public API

    /// Bundled extension version — bump this when updating the VSIX
    static let bundledVersion = "1.0.0"

    /// Re-install the extension if the bundled version is newer than what was last installed.
    /// Called on app launch to ensure updates propagate automatically.
    static func upgradeIfNeeded() {
        let lastInstalled = UserDefaults.standard.string(forKey: "ideExtensionVersion") ?? "0"
        guard bundledVersion.compare(lastInstalled, options: .numeric) == .orderedDescending else { return }
        DispatchQueue.global(qos: .utility).async {
            do {
                try install()
                UserDefaults.standard.set(bundledVersion, forKey: "ideExtensionVersion")
            } catch {
                print("[masko-desktop] Extension upgrade failed: \(error)")
            }
        }
    }

    /// Check if the extension is installed in any detected IDE
    static func isInstalled() -> Bool {
        // VS Code family
        for ide in vscodeConfigs {
            if let path = resolveCommand(ide),
               extensionInstalled(cliPath: path) {
                return true
            }
        }
        // JetBrains family
        for jb in jetbrainsConfigs {
            if FileManager.default.fileExists(atPath: jb.appPath),
               jetbrainsPluginInstalled(bundleId: jb.bundleId) {
                return true
            }
        }
        return false
    }

    /// Detect which IDEs are available on the system
    static func availableIDEs() -> [(name: String, command: String)] {
        var result = vscodeConfigs.compactMap { ide -> (name: String, command: String)? in
            resolveCommand(ide) != nil
                ? (name: ideName(for: ide.command), command: ide.command)
                : nil
        }
        result += jetbrainsConfigs.compactMap { jb in
            FileManager.default.fileExists(atPath: jb.appPath)
                ? (name: jb.name, command: jb.scheme)
                : nil
        }
        return result
    }

    /// Install the extension into all detected IDEs (skips IDEs with skipAutoInstall)
    static func install() throws {
        var installed = false

        // VS Code family: install via CLI
        let vsixPath = bundledVSIXPath()
        if FileManager.default.fileExists(atPath: vsixPath) {
            for ide in vscodeConfigs {
                if ide.skipAutoInstall { continue }
                guard let cliPath = resolveCommand(ide) else { continue }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: cliPath)
                process.arguments = ["--install-extension", vsixPath, "--force"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    installed = true
                }
            }
        }

        // JetBrains family: copy plugin to plugins directory
        let jbPluginPath = bundledJetBrainsPluginPath()
        if FileManager.default.fileExists(atPath: jbPluginPath) {
            for jb in jetbrainsConfigs {
                guard FileManager.default.fileExists(atPath: jb.appPath) else { continue }
                if (try? installJetBrainsPlugin(jbPluginPath, bundleId: jb.bundleId)) == true {
                    installed = true
                }
            }
        }

        if !installed {
            throw ExtensionError.noIDEFound
        }
    }

    /// Install the extension into a single IDE by command name
    static func install(command: String) throws {
        // Check VS Code family first
        if let ide = vscodeConfigs.first(where: { $0.command == command }),
           let cliPath = resolveCommand(ide) {
            let vsixPath = bundledVSIXPath()
            guard FileManager.default.fileExists(atPath: vsixPath) else {
                throw ExtensionError.vsixNotFound
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = ["--install-extension", vsixPath, "--force"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw ExtensionError.noIDEFound
            }
            return
        }

        // Check JetBrains family (command = scheme for JetBrains)
        if let jb = jetbrainsConfigs.first(where: { $0.scheme == command }),
           FileManager.default.fileExists(atPath: jb.appPath) {
            let jbPluginPath = bundledJetBrainsPluginPath()
            guard FileManager.default.fileExists(atPath: jbPluginPath) else {
                throw ExtensionError.pluginNotFound
            }
            try installJetBrainsPlugin(jbPluginPath, bundleId: jb.bundleId)
            return
        }

        throw ExtensionError.noIDEFound
    }

    /// Uninstall the extension from all detected IDEs
    static func uninstall() {
        // VS Code family
        for ide in vscodeConfigs {
            guard let cliPath = resolveCommand(ide) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = ["--uninstall-extension", extensionId]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
        // JetBrains family
        for jb in jetbrainsConfigs {
            guard let pluginsDir = jetbrainsPluginsDir(bundleId: jb.bundleId) else { continue }
            let pluginDir = (pluginsDir as NSString).appendingPathComponent("masko-terminal-focus")
            try? FileManager.default.removeItem(atPath: pluginDir)
        }
    }

    /// Open a test URI so the IDE shows the "allow this extension?" popup right away.
    static func triggerPermissionPrompt() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            // Try VS Code family first
            for ide in vscodeConfigs {
                guard resolveCommand(ide) != nil else { continue }
                if let url = URL(string: "\(ide.scheme)://masko.masko-terminal-focus/setup") {
                    NSWorkspace.shared.open(url)
                    return
                }
            }
            // Try JetBrains family
            for jb in jetbrainsConfigs {
                guard FileManager.default.fileExists(atPath: jb.appPath) else { continue }
                if let url = URL(string: "\(jb.scheme)://masko-terminal-focus/setup") {
                    NSWorkspace.shared.open(url)
                    return
                }
            }
        }
    }

    /// Get the URI scheme for a given terminal PID's IDE bundle
    static func uriScheme(forBundleId bundleId: String?) -> String? {
        guard let bundleId else { return nil }
        if let vscode = vscodeConfigs.first(where: { $0.bundleId == bundleId }) {
            return vscode.scheme
        }
        if let jb = jetbrainsConfigs.first(where: { $0.bundleId == bundleId }) {
            return jb.scheme
        }
        return nil
    }

    /// Whether the given bundle ID belongs to a JetBrains IDE
    static func isJetBrainsIDE(bundleId: String?) -> Bool {
        guard let bundleId else { return false }
        return jetbrainsConfigs.contains { $0.bundleId == bundleId }
    }

    // MARK: - Private

    /// Find the CLI binary — try `which` first, then fall back to known paths
    private static func resolveCommand(
        _ ide: (bundleId: String, command: String, scheme: String, paths: [String], skipAutoInstall: Bool)
    ) -> String? {
        // Try which first (works when the user has the CLI in their PATH)
        if let path = whichCommand(ide.command) {
            return path
        }
        // Fall back to common install locations
        for path in ide.paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private static func whichCommand(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (path?.isEmpty == false) ? path : nil
        } catch {
            return nil
        }
    }

    private static func extensionInstalled(cliPath: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["--list-extensions"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.contains(extensionId)
        } catch {
            return false
        }
    }

    private static func bundledVSIXPath() -> String {
        // SPM Bundle.module resources (auto-generated accessor for .copy() resources)
        let moduleBundle = Bundle.module
        if let url = moduleBundle.url(forResource: "masko-terminal-focus", withExtension: "vsix", subdirectory: "Extensions") {
            return url.path
        }
        // Main app bundle fallback
        if let path = Bundle.main.path(forResource: "masko-terminal-focus", ofType: "vsix") {
            return path
        }
        // Development fallback
        return NSHomeDirectory() + "/.masko-desktop/extensions/masko-terminal-focus.vsix"
    }

    private static func ideName(for command: String) -> String {
        switch command {
        case "cursor": return "Cursor"
        case "code": return "VS Code"
        case "code-insiders": return "VS Code Insiders"
        case "windsurf": return "Windsurf"
        case "antigravity": return "Antigravity"
        default: return command
        }
    }

    // MARK: - JetBrains Plugin Helpers

    /// Find the plugins directory for a JetBrains IDE.
    /// Path: ~/Library/Application Support/JetBrains/<ProductVersion>/plugins/
    private static func jetbrainsPluginsDir(bundleId: String) -> String? {
        let supportDir = NSHomeDirectory() + "/Library/Application Support/JetBrains"
        guard FileManager.default.fileExists(atPath: supportDir) else { return nil }

        // Map bundle ID to directory prefix (e.g., "com.jetbrains.pycharm" -> "PyCharm")
        let prefix = jetbrainsDirPrefix(bundleId: bundleId)
        guard let prefix else { return nil }

        // Find the most recent version directory
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: supportDir) else { return nil }
        let matching = contents
            .filter { $0.hasPrefix(prefix) }
            .sorted()  // Lexicographic sort puts newest version last
            .last

        guard let dir = matching else { return nil }
        return (supportDir as NSString).appendingPathComponent(dir + "/plugins")
    }

    /// Map JetBrains bundle ID to the directory name prefix in ~/Library/Application Support/JetBrains/
    private static func jetbrainsDirPrefix(bundleId: String) -> String? {
        let map: [String: String] = [
            "com.jetbrains.pycharm": "PyCharm",
            "com.jetbrains.pycharm.ce": "PyCharmCE",
            "com.jetbrains.intellij": "IntelliJIdea",
            "com.jetbrains.intellij.ce": "IdeaIC",
            "com.jetbrains.WebStorm": "WebStorm",
            "com.jetbrains.goland": "GoLand",
            "com.jetbrains.CLion": "CLion",
            "com.jetbrains.PhpStorm": "PhpStorm",
            "com.jetbrains.rubymine": "RubyMine",
            "com.jetbrains.rider": "Rider",
        ]
        return map[bundleId]
    }

    /// Check if the Masko plugin is installed in a JetBrains IDE
    private static func jetbrainsPluginInstalled(bundleId: String) -> Bool {
        guard let pluginsDir = jetbrainsPluginsDir(bundleId: bundleId) else { return false }
        let pluginDir = (pluginsDir as NSString).appendingPathComponent("masko-terminal-focus")
        return FileManager.default.fileExists(atPath: pluginDir)
    }

    /// Install the JetBrains plugin by extracting it to the plugins directory.
    /// The plugin zip contains a top-level "masko-terminal-focus/" directory.
    @discardableResult
    private static func installJetBrainsPlugin(_ zipPath: String, bundleId: String) throws -> Bool {
        // Resolve or create the plugins directory
        let supportDir = NSHomeDirectory() + "/Library/Application Support/JetBrains"

        var pluginsDir: String
        if let existing = jetbrainsPluginsDir(bundleId: bundleId) {
            pluginsDir = existing
        } else {
            // IDE detected but no support dir yet - create one using the app's version
            guard let prefix = jetbrainsDirPrefix(bundleId: bundleId),
                  let version = jetbrainsVersion(bundleId: bundleId) else {
                return false
            }
            pluginsDir = "\(supportDir)/\(prefix)\(version)/plugins"
        }

        try FileManager.default.createDirectory(atPath: pluginsDir, withIntermediateDirectories: true)

        // Remove old version if present
        let destDir = (pluginsDir as NSString).appendingPathComponent("masko-terminal-focus")
        if FileManager.default.fileExists(atPath: destDir) {
            try FileManager.default.removeItem(atPath: destDir)
        }

        // Unzip the plugin
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", zipPath, "-d", pluginsDir]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        return process.terminationStatus == 0
    }

    /// Extract the major version from a JetBrains app bundle (e.g., "2025.3")
    private static func jetbrainsVersion(bundleId: String) -> String? {
        guard let jb = jetbrainsConfigs.first(where: { $0.bundleId == bundleId }) else { return nil }
        let plistPath = jb.appPath + "/Contents/Info.plist"
        guard let plist = NSDictionary(contentsOfFile: plistPath),
              let version = plist["CFBundleShortVersionString"] as? String else { return nil }
        // Extract major.minor (e.g., "2025.3.3" -> "2025.3")
        let parts = version.split(separator: ".")
        guard parts.count >= 2 else { return version }
        return "\(parts[0]).\(parts[1])"
    }

    /// Path to the bundled JetBrains plugin zip
    private static func bundledJetBrainsPluginPath() -> String {
        let moduleBundle = Bundle.module
        if let url = moduleBundle.url(forResource: "masko-terminal-focus-jetbrains", withExtension: "zip", subdirectory: "Extensions") {
            return url.path
        }
        if let path = Bundle.main.path(forResource: "masko-terminal-focus-jetbrains", ofType: "zip") {
            return path
        }
        return NSHomeDirectory() + "/.masko-desktop/extensions/masko-terminal-focus-jetbrains.zip"
    }

    enum ExtensionError: LocalizedError {
        case vsixNotFound
        case pluginNotFound
        case noIDEFound

        var errorDescription: String? {
            switch self {
            case .vsixNotFound: return "VS Code extension file not found in app bundle"
            case .pluginNotFound: return "JetBrains plugin file not found in app bundle"
            case .noIDEFound: return "No supported IDE found (Cursor, VS Code, Windsurf, JetBrains)"
            }
        }
    }
}

import AppKit
import Foundation

/// Shared utility for focusing the terminal running a Claude Code session.
/// Attempts IDE extension URI first (exact tab), falls back to AppleScript app activation.
enum IDETerminalFocus {

    /// Focus the terminal for a given session.
    static func focusSession(_ session: AgentSession) {
        focus(terminalPid: session.terminalPid, shellPid: session.shellPid, projectDir: session.projectDir, savedBundleId: session.terminalBundleId)
    }

    /// Focus a terminal by PID.
    /// 1. If shellPid + IDE extension available → bring correct window to front, then open URI to focus exact terminal tab
    /// 2. If terminalPid available → activate the IDE/terminal app (brings to foreground)
    /// 3. Fallback → activate first running terminal-like app
    static func focus(terminalPid: Int? = nil, shellPid: Int? = nil, projectDir: String? = nil, savedBundleId: String? = nil) {
        // Resolve bundle ID from terminalPid, fall back to persisted bundleId
        var bundleId: String?
        if let pid = terminalPid,
           let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
            bundleId = app.bundleIdentifier
        }
        if bundleId == nil {
            bundleId = savedBundleId
        }

        // Try IDE extension for exact terminal tab focus
        if let shellPid,
           let bundleId,
           UserDefaults.standard.bool(forKey: "ideExtensionEnabled") {
            // Bring the correct workspace window to front (handles multi-window IDEs like Cursor)
            if let projectDir {
                bringWindowToFront(bundleId: bundleId, projectDir: projectDir)
            } else if let pid = terminalPid,
               let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
                app.activate()
            }

            // JetBrains: activate via AppleScript (works across fullscreen/Spaces),
            // then HTTP request to built-in server for terminal tab focus
            if ExtensionInstaller.isJetBrainsIDE(bundleId: bundleId) {
                activateApp(bundleId: bundleId)
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) {
                    let url = URL(string: "http://localhost:63342/api/masko/focus?pid=\(shellPid)")!
                    var request = URLRequest(url: url, timeoutInterval: 1)
                    request.httpMethod = "GET"
                    URLSession.shared.dataTask(with: request).resume()
                }
                return
            }

            // VS Code family: URI scheme to extension
            if let scheme = ExtensionInstaller.uriScheme(forBundleId: bundleId) {
                let urlString = "\(scheme)://masko.masko-terminal-focus/focus?pid=\(shellPid)"
                if let url = URL(string: urlString) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        NSWorkspace.shared.open(url)
                    }
                    return
                }
            }
        }

        // For multi-window IDEs (VS Code, Cursor, etc.), use `open -b` to raise the correct workspace window
        if let projectDir, let bundleId {
            bringWindowToFront(bundleId: bundleId, projectDir: projectDir)
            return
        }

        // Try terminal-specific tab switching (iTerm2, Terminal.app)
        if let shellPid, let bundleId {
            if activateTerminalTab(bundleId: bundleId, shellPid: shellPid) {
                return
            }
        }

        // Try to raise the specific window by title (handles multiple fullscreen windows)
        if let projectDir, let pid = terminalPid,
           let app = NSRunningApplication(processIdentifier: pid_t(pid)),
           let processName = app.localizedName {
            let folderName = (projectDir as NSString).lastPathComponent
            if raiseWindowByTitle(processName: processName, titleContains: folderName) {
                return
            }
        }

        // Activate the SPECIFIC process by PID (correct window with multiple instances)
        // Falls through to AppleScript if activate() fails (common on macOS 14+ across Spaces)
        if let pid = terminalPid,
           let app = NSRunningApplication(processIdentifier: pid_t(pid)),
           app.activate() {
            return
        }

        // Fallback: bring IDE/terminal to foreground by bundle ID (no specific PID)
        if let bundleId {
            activateApp(bundleId: bundleId)
            return
        }
        // Last resort: find any running terminal app
        let bundleIDs = [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.github.wez.wezterm",
            "net.kovidgoyal.kitty",
            "com.todesktop.230313mzl4w4u92",
            "com.microsoft.VSCode",
            "com.microsoft.VSCodeInsiders",
            "com.exafunction.windsurf",
            "dev.zed.Zed",
            "com.mitchellh.ghostty",
            "org.alacritty",
            "dev.warp.Warp-Stable",
            "com.google.antigravity",
            "com.jetbrains.pycharm",
            "com.jetbrains.pycharm.ce",
            "com.jetbrains.intellij",
            "com.jetbrains.intellij.ce",
            "com.jetbrains.WebStorm",
            "com.jetbrains.goland",
            "com.jetbrains.CLion",
            "com.jetbrains.PhpStorm",
            "com.jetbrains.rubymine",
            "com.jetbrains.rider",
        ]
        for id in bundleIDs {
            if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == id }) {
                activateApp(bundleId: id)
                return
            }
        }
    }

    /// Get the tty name for a given PID (e.g. "ttys003").
    private static func ttyForPid(_ pid: Int) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "tty=", "-p", "\(pid)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { return nil }
    }

    /// Try to switch to the exact terminal tab matching shellPid's tty.
    /// Returns true if a terminal-specific AppleScript succeeded.
    private static func activateTerminalTab(bundleId: String, shellPid: Int) -> Bool {
        guard let tty = ttyForPid(shellPid), !tty.isEmpty else { return false }
        let ttyDevice = "/dev/\(tty)"

        let script: String?
        switch bundleId {
        case "com.googlecode.iterm2":
            script = """
            tell application "iTerm2"
                activate
                repeat with aWindow in windows
                    repeat with aTab in tabs of aWindow
                        repeat with aSession in sessions of aTab
                            if tty of aSession is "\(ttyDevice)" then
                                select aTab
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """
        case "com.apple.Terminal":
            script = """
            tell application "Terminal"
                activate
                repeat with aWindow in windows
                    repeat with aTab in tabs of aWindow
                        if tty of aTab is "\(ttyDevice)" then
                            set selected tab of aWindow to aTab
                            set index of aWindow to 1
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """
        default:
            script = nil
        }

        guard let src = script else { return false }
        // Try in-process first (works in .app bundle with NSAppleEventsUsageDescription)
        if let appleScript = NSAppleScript(source: src) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error {
                let code = error[NSAppleScript.errorNumber] as? Int ?? 0
                // -1743 = not authorized — try osascript subprocess as fallback
                if code == -1743 {
                    return runOsascript(src)
                }
                return false
            }
            return true
        }
        return false
    }

    /// Run AppleScript via osascript subprocess (inherits caller's Automation permissions).
    private static func runOsascript(_ source: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Bring the correct IDE window to front by opening its workspace path.
    /// `open -b <bundleId> <projectDir>` tells macOS to activate the window for that workspace.
    private static func bringWindowToFront(bundleId: String, projectDir: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", bundleId, projectDir]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// Raise a specific window by matching its title. Uses Accessibility API via AppleScript
    /// which works across fullscreen Spaces. Returns true if a matching window was found and raised.
    @discardableResult
    private static func raiseWindowByTitle(processName: String, titleContains: String) -> Bool {
        let escapedProcess = processName.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedTitle = titleContains.replacingOccurrences(of: "\"", with: "\\\"")
        let src = """
        tell application "System Events"
            set targetProcess to first process whose name is "\(escapedProcess)"
            repeat with aWindow in windows of targetProcess
                if name of aWindow contains "\(escapedTitle)" then
                    perform action "AXRaise" of aWindow
                    set frontmost of targetProcess to true
                    return true
                end if
            end repeat
        end tell
        return false
        """
        if let script = NSAppleScript(source: src) {
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            if error == nil {
                return result.booleanValue
            }
            // Try osascript fallback
            return runOsascript(src)
        }
        return false
    }

    /// AppleScript `tell application id` — most reliable cross-Space activation on macOS 14+.
    private static func activateApp(bundleId: String) {
        let src = "tell application id \"\(bundleId)\" to activate"
        if let script = NSAppleScript(source: src) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
        }
    }
}

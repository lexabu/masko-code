import Foundation

/// Optional Codex app-server JSON-RPC transport.
/// Runs `codex app-server --listen stdio://` as a child process, forwards
/// mapped events into the shared Masko pipeline, and can resolve server requests.
final class CodexAppServerClient {
    struct ProcessConfig {
        let launchPath: String
        let arguments: [String]

        static let `default` = ProcessConfig(
            launchPath: "/usr/bin/env",
            arguments: ["codex", "app-server", "--listen", "stdio://"]
        )
    }

    struct PendingRequest {
        struct Question {
            let id: String
            let prompt: String
        }

        let rawId: Any
        let requestId: String
        let method: String
        let threadId: String?
        let turnId: String?
        let itemId: String?
        let approvalId: String?
        let questions: [Question]
        let requestedPermissions: [String: Any]?
        let proposedExecpolicyAmendment: [String]
    }

    private let processConfig: ProcessConfig
    private let clientName: String
    private let clientVersion: String

    private(set) var isRunning = false

    var onEventReceived: ((ClaudeEvent) -> Void)?

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()

    private var nextClientRequestId = 1
    private var pendingServerRequests: [String: PendingRequest] = [:]

    init(
        processConfig: ProcessConfig = .default,
        clientName: String = "masko-desktop",
        clientVersion: String = "0.1.0"
    ) {
        self.processConfig = processConfig
        self.clientName = clientName
        self.clientVersion = clientVersion
    }

    func start() {
        guard process == nil else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: processConfig.launchPath)
        proc.arguments = processConfig.arguments

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        proc.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRunning = false
                self.process = nil
                self.stdinHandle = nil
                self.stdoutHandle?.readabilityHandler = nil
                self.stdoutHandle = nil
                self.stderrHandle?.readabilityHandler = nil
                self.stderrHandle = nil
                self.pendingServerRequests.removeAll()
                print("[masko-desktop] Codex app-server exited status=\(process.terminationStatus)")
            }
        }

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consumeStdout(data)
        }

        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consumeStderr(data)
        }

        do {
            try proc.run()
            process = proc
            stdinHandle = stdin.fileHandleForWriting
            stdoutHandle = stdout.fileHandleForReading
            stderrHandle = stderr.fileHandleForReading
            isRunning = true

            sendInitializeHandshake()
            print("[masko-desktop] Codex app-server started")
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            print("[masko-desktop] Failed to start Codex app-server: \(error)")
        }
    }

    func stop() {
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        stdinHandle = nil
        pendingServerRequests.removeAll()
        if let process {
            process.terminate()
        }
        self.process = nil
        isRunning = false
    }

    /// Resolve a pending app-server request using the mascot decision.
    func submit(resolution: LocalPermissionResolution, event: ClaudeEvent) -> Bool {
        guard let requestId = requestId(for: event),
              let pending = pendingServerRequests[requestId] else {
            return false
        }

        guard let result = responseResult(for: pending, resolution: resolution) else {
            return false
        }

        let response: [String: Any] = [
            "id": pending.rawId,
            "result": result,
        ]

        let sent = sendJSON(response)
        if sent {
            pendingServerRequests.removeValue(forKey: requestId)
            print("[masko-desktop] Codex app-server resolved request id=\(requestId) method=\(pending.method)")
        }
        return sent
    }

    static func supportsBackgroundReplies(for event: ClaudeEvent) -> Bool {
        let source = event.source?.lowercased() ?? ""
        return source.contains("codex-app-server")
    }

    // MARK: - IO

    private func consumeStdout(_ data: Data) {
        DispatchQueue.main.async {
            self.stdoutBuffer.append(data)

            while let newline = self.stdoutBuffer.firstIndex(of: 0x0A) {
                let lineData = self.stdoutBuffer.subdata(in: 0..<newline)
                self.stdoutBuffer.removeSubrange(0...newline)
                self.handleStdoutLine(lineData)
            }
        }
    }

    private func consumeStderr(_ data: Data) {
        DispatchQueue.main.async {
            self.stderrBuffer.append(data)

            while let newline = self.stderrBuffer.firstIndex(of: 0x0A) {
                let lineData = self.stderrBuffer.subdata(in: 0..<newline)
                self.stderrBuffer.removeSubrange(0...newline)
                if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                    print("[masko-desktop] Codex app-server stderr: \(line)")
                }
            }
        }
    }

    private func handleStdoutLine(_ lineData: Data) {
        guard !lineData.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            return
        }

        if let method = object["method"] as? String {
            if object["id"] != nil {
                handleServerRequest(method: method, message: object)
            } else {
                handleServerNotification(method: method, message: object)
            }
            return
        }

        // Response to our own request (initialize etc.) - currently no-op.
    }

    private func sendInitializeHandshake() {
        let initializeId = nextClientRequestId
        nextClientRequestId += 1

        let initialize: [String: Any] = [
            "id": initializeId,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": clientName,
                    "title": "Masko Desktop",
                    "version": clientVersion,
                ],
                "capabilities": [
                    "experimentalApi": true,
                ],
            ],
        ]

        let initialized: [String: Any] = [
            "method": "initialized",
            "params": [:],
        ]

        _ = sendJSON(initialize)
        _ = sendJSON(initialized)
    }

    private func sendJSON(_ object: [String: Any]) -> Bool {
        guard let stdinHandle else {
            return false
        }

        var payload = object
        if payload["jsonrpc"] == nil {
            payload["jsonrpc"] = "2.0"
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return false
        }

        stdinHandle.write(data)
        stdinHandle.write(Data([0x0A]))
        return true
    }

    // MARK: - Server Request Mapping

    private func handleServerRequest(method: String, message: [String: Any]) {
        guard let rawId = message["id"],
              let requestId = Self.requestIdString(from: rawId) else {
            return
        }

        let params = message["params"] as? [String: Any] ?? [:]

        if let mapped = Self.mapServerRequest(method: method, params: params, requestId: requestId, rawId: rawId) {
            pendingServerRequests[requestId] = mapped.pending
            onEventReceived?(mapped.event)
            return
        }

        // Unknown request: reject so Codex is not left waiting forever.
        let errorResponse: [String: Any] = [
            "id": rawId,
            "error": [
                "code": -32601,
                "message": "Method not supported by Masko app-server bridge: \(method)",
            ],
        ]
        _ = sendJSON(errorResponse)
    }

    static func mapServerRequest(
        method: String,
        params: [String: Any],
        requestId: String,
        rawId: Any
    ) -> (event: ClaudeEvent, pending: PendingRequest)? {
        let threadId = (params["threadId"] as? String) ?? (params["conversationId"] as? String)
        let turnId = params["turnId"] as? String
        let itemId = (params["itemId"] as? String) ?? (params["callId"] as? String)
        let approvalId = params["approvalId"] as? String
        let requestToolUseId = requestId

        var toolInput: [String: Any] = [
            "codex_app_server_request_id": requestId,
            "codex_app_server_method": method,
        ]
        if let itemId, !itemId.isEmpty {
            toolInput["codex_app_server_item_id"] = itemId
        }
        if let approvalId, !approvalId.isEmpty {
            toolInput["codex_app_server_approval_id"] = approvalId
        }
        var toolName: String?
        var message: String?
        var permissionSuggestions: [AnyCodable]?
        var questions: [PendingRequest.Question] = []
        var requestedPermissions: [String: Any]?
        var proposedExecpolicyAmendment: [String] = []

        switch method {
        case "item/commandExecution/requestApproval":
            toolName = "exec_command"
            if let command = params["command"] as? String, !command.isEmpty {
                toolInput["cmd"] = command
            }
            if let cwd = params["cwd"] as? String {
                toolInput["cwd"] = cwd
            }
            if let reason = params["reason"] as? String, !reason.isEmpty {
                message = reason
                toolInput["reason"] = reason
            }
            toolInput["sandbox_permissions"] = "require_escalated"

            if let proposed = params["proposedExecpolicyAmendment"] as? [String] {
                proposedExecpolicyAmendment = proposed.filter { !$0.isEmpty }
            }
            if !proposedExecpolicyAmendment.isEmpty {
                permissionSuggestions = [
                    AnyCodable([
                        "type": "addRules",
                        "destination": "session",
                        "rules": proposedExecpolicyAmendment.map { rule in [
                            "toolName": "exec_command",
                            "ruleContent": rule,
                        ] },
                    ]),
                ]
            }

        case "execCommandApproval":
            toolName = "exec_command"
            if let callId = params["callId"] as? String, !callId.isEmpty {
                toolInput["callId"] = callId
            }
            if let command = params["command"] as? [String], !command.isEmpty {
                toolInput["command"] = command
                toolInput["cmd"] = command.joined(separator: " ")
            } else if let command = params["command"] as? String, !command.isEmpty {
                toolInput["cmd"] = command
            }
            if let cwd = params["cwd"] as? String {
                toolInput["cwd"] = cwd
            }
            if let reason = params["reason"] as? String, !reason.isEmpty {
                message = reason
                toolInput["reason"] = reason
            }
            if let proposed = params["proposedExecpolicyAmendment"] as? [String] {
                proposedExecpolicyAmendment = proposed.filter { !$0.isEmpty }
            }
            if !proposedExecpolicyAmendment.isEmpty {
                permissionSuggestions = [
                    AnyCodable([
                        "type": "addRules",
                        "destination": "session",
                        "rules": proposedExecpolicyAmendment.map { rule in [
                            "toolName": "exec_command",
                            "ruleContent": rule,
                        ] },
                    ]),
                ]
            }
            toolInput["sandbox_permissions"] = "require_escalated"

        case "item/fileChange/requestApproval", "applyPatchApproval":
            toolName = "apply_patch"
            if let callId = params["callId"] as? String, !callId.isEmpty {
                toolInput["callId"] = callId
            }
            if let reason = params["reason"] as? String, !reason.isEmpty {
                message = reason
                toolInput["reason"] = reason
            }
            if let grantRoot = params["grantRoot"] as? String {
                toolInput["grantRoot"] = grantRoot
            }

        case "item/permissions/requestApproval":
            toolName = "request_permissions"
            if let reason = params["reason"] as? String, !reason.isEmpty {
                message = reason
                toolInput["reason"] = reason
            }
            if let permissions = params["permissions"] as? [String: Any] {
                requestedPermissions = permissions
                toolInput["permissions"] = permissions
            }

        case "item/tool/requestUserInput":
            toolName = "AskUserQuestion"
            let questionObjs = (params["questions"] as? [[String: Any]]) ?? []
            var promptTexts: [String] = []
            for q in questionObjs {
                let id = (q["id"] as? String) ?? UUID().uuidString
                let prompt = (q["question"] as? String) ?? ""
                questions.append(PendingRequest.Question(id: id, prompt: prompt))
                if !prompt.isEmpty {
                    promptTexts.append(prompt)
                }
            }
            if !questionObjs.isEmpty {
                toolInput["questions"] = questionObjs
            }
            message = promptTexts.first

        case "mcpServer/elicitation/request":
            toolName = "AskUserQuestion"
            if let prompt = params["message"] as? String, !prompt.isEmpty {
                message = prompt
                toolInput["questions"] = [[
                    "id": (params["elicitationId"] as? String) ?? "elicitation",
                    "question": prompt,
                    "options": [],
                ]]
                questions.append(PendingRequest.Question(
                    id: (params["elicitationId"] as? String) ?? "elicitation",
                    prompt: prompt
                ))
            }
            if let mode = params["mode"] as? String {
                toolInput["mode"] = mode
            }

        default:
            return nil
        }

        let event = ClaudeEvent(
            hookEventName: HookEventType.permissionRequest.rawValue,
            sessionId: threadId,
            cwd: params["cwd"] as? String,
            toolName: toolName,
            toolInput: toolInput.mapValues(AnyCodable.init),
            toolUseId: requestToolUseId,
            message: message,
            source: "codex-app-server",
            taskId: turnId,
            permissionSuggestions: permissionSuggestions
        )

        let pending = PendingRequest(
            rawId: rawId,
            requestId: requestId,
            method: method,
            threadId: threadId,
            turnId: turnId,
            itemId: itemId,
            approvalId: approvalId,
            questions: questions,
            requestedPermissions: requestedPermissions,
            proposedExecpolicyAmendment: proposedExecpolicyAmendment
        )

        return (event, pending)
    }

    // MARK: - Notification Mapping

    private func handleServerNotification(method: String, message: [String: Any]) {
        guard let params = message["params"] as? [String: Any] else { return }
        let events = Self.mapServerNotification(method: method, params: params)
        for event in events {
            onEventReceived?(event)
        }
    }

    static func mapServerNotification(method: String, params: [String: Any]) -> [ClaudeEvent] {
        switch method {
        case "thread/started":
            let thread = params["thread"] as? [String: Any]
            let threadId = thread?["id"] as? String
            return [ClaudeEvent(
                hookEventName: HookEventType.sessionStart.rawValue,
                sessionId: threadId,
                source: "codex-app-server"
            )]

        case "turn/started":
            let threadId = params["threadId"] as? String
            let turn = params["turn"] as? [String: Any]
            return [ClaudeEvent(
                hookEventName: HookEventType.userPromptSubmit.rawValue,
                sessionId: threadId,
                source: "codex-app-server",
                taskId: turn?["id"] as? String
            )]

        case "turn/completed":
            let threadId = params["threadId"] as? String
            let turn = params["turn"] as? [String: Any]
            let status = (turn?["status"] as? String) ?? "completed"
            let reason: String
            switch status {
            case "interrupted":
                reason = "interrupted"
            case "failed":
                reason = "failed"
            default:
                reason = "completed"
            }
            let stop = ClaudeEvent(
                hookEventName: HookEventType.stop.rawValue,
                sessionId: threadId,
                source: "codex-app-server",
                reason: reason,
                taskId: turn?["id"] as? String
            )
            if status == "completed" {
                let completed = ClaudeEvent(
                    hookEventName: HookEventType.taskCompleted.rawValue,
                    sessionId: threadId,
                    source: "codex-app-server",
                    taskId: turn?["id"] as? String
                )
                return [stop, completed]
            }
            return [stop]

        case "serverRequest/resolved":
            let threadId = params["threadId"] as? String
            let requestId = requestIdString(from: params["requestId"])
            guard let requestId, !requestId.isEmpty else { return [] }
            return [ClaudeEvent(
                hookEventName: HookEventType.postToolUse.rawValue,
                sessionId: threadId,
                toolName: "server_request_resolved",
                toolUseId: requestId,
                source: "codex-app-server"
            )]

        case "item/started", "item/completed":
            return mapItemLifecycleNotification(method: method, params: params)

        case "item/agentMessage/delta":
            let threadId = params["threadId"] as? String
            let delta = params["delta"] as? String
            guard let delta, !delta.isEmpty else { return [] }
            return [ClaudeEvent(
                hookEventName: HookEventType.notification.rawValue,
                sessionId: threadId,
                message: delta,
                notificationType: "codex_agent_message",
                source: "codex-app-server"
            )]

        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            let threadId = params["threadId"] as? String
            let delta = params["delta"] as? String
            guard let delta, !delta.isEmpty else { return [] }
            return [ClaudeEvent(
                hookEventName: HookEventType.notification.rawValue,
                sessionId: threadId,
                message: delta,
                notificationType: "codex_agent_reasoning",
                source: "codex-app-server"
            )]

        default:
            return []
        }
    }

    private static func mapItemLifecycleNotification(method: String, params: [String: Any]) -> [ClaudeEvent] {
        guard let item = params["item"] as? [String: Any],
              let itemType = item["type"] as? String,
              let itemId = item["id"] as? String else {
            return []
        }

        let threadId = params["threadId"] as? String
        let turnId = params["turnId"] as? String
        var toolInput: [String: Any] = [:]
        var toolName: String?
        var status: String?
        var failureMessage: String?
        var cwd: String?

        switch itemType {
        case "commandExecution":
            toolName = "exec_command"
            status = item["status"] as? String
            if let command = item["command"] as? String, !command.isEmpty {
                toolInput["cmd"] = command
            }
            if let commandCwd = item["cwd"] as? String, !commandCwd.isEmpty {
                cwd = commandCwd
                toolInput["cwd"] = commandCwd
            }
            if let output = item["aggregatedOutput"] as? String, !output.isEmpty {
                toolInput["output"] = output
                if status == "failed" || status == "declined" {
                    failureMessage = output
                }
            }
            if let exitCode = item["exitCode"] {
                toolInput["exitCode"] = exitCode
            }

        case "fileChange":
            toolName = "apply_patch"
            status = item["status"] as? String
            if let changes = item["changes"] as? [[String: Any]], !changes.isEmpty {
                toolInput["changes"] = changes
            }

        case "mcpToolCall":
            toolName = (item["tool"] as? String).flatMap { $0.isEmpty ? nil : "mcp:\($0)" } ?? "mcp_tool_call"
            status = item["status"] as? String
            if let arguments = item["arguments"] {
                toolInput["arguments"] = arguments
            }
            if let server = item["server"] as? String, !server.isEmpty {
                toolInput["server"] = server
            }
            if let error = item["error"] as? [String: Any],
               let message = error["message"] as? String,
               !message.isEmpty {
                failureMessage = message
            }

        case "dynamicToolCall":
            toolName = (item["tool"] as? String).flatMap { $0.isEmpty ? nil : "dynamic:\($0)" } ?? "dynamic_tool_call"
            status = item["status"] as? String
            if let arguments = item["arguments"] {
                toolInput["arguments"] = arguments
            }

        default:
            return []
        }

        guard let toolName,
              let hookEventName = lifecycleHookEventName(method: method, status: status) else {
            return []
        }

        let event = ClaudeEvent(
            hookEventName: hookEventName,
            sessionId: threadId,
            cwd: cwd,
            toolName: toolName,
            toolInput: toolInput.isEmpty ? nil : toolInput.mapValues(AnyCodable.init),
            toolUseId: itemId,
            message: failureMessage,
            source: "codex-app-server",
            taskId: turnId
        )
        return [event]
    }

    private static func lifecycleHookEventName(method: String, status: String?) -> String? {
        if method == "item/started" {
            return HookEventType.preToolUse.rawValue
        }

        switch status {
        case "completed":
            return HookEventType.postToolUse.rawValue
        case "failed", "declined":
            return HookEventType.postToolUseFailure.rawValue
        case "inProgress":
            return HookEventType.preToolUse.rawValue
        default:
            return nil
        }
    }

    // MARK: - Resolution Mapping

    private func requestId(for event: ClaudeEvent) -> String? {
        if let rid = event.toolInput?["codex_app_server_request_id"]?.stringValue, !rid.isEmpty {
            return rid
        }
        if let toolUseId = event.toolUseId, pendingServerRequests[toolUseId] != nil {
            return toolUseId
        }
        return nil
    }

    private func responseResult(for pending: PendingRequest, resolution: LocalPermissionResolution) -> [String: Any]? {
        switch pending.method {
        case "item/commandExecution/requestApproval":
            return ["decision": commandApprovalDecision(pending: pending, resolution: resolution)]

        case "execCommandApproval", "applyPatchApproval":
            return ["decision": legacyApprovalDecision(pending: pending, resolution: resolution)]

        case "item/fileChange/requestApproval":
            return ["decision": fileChangeDecision(resolution: resolution)]

        case "item/permissions/requestApproval":
            return permissionsApprovalResult(pending: pending, resolution: resolution)

        case "item/tool/requestUserInput":
            return requestUserInputResult(pending: pending, resolution: resolution)

        case "mcpServer/elicitation/request":
            return mcpElicitationResult(resolution: resolution)

        default:
            return nil
        }
    }

    private func commandApprovalDecision(pending: PendingRequest, resolution: LocalPermissionResolution) -> Any {
        switch resolution {
        case .decision(let decision):
            return decision == .allow ? "accept" : "decline"
        case .answers:
            return "accept"
        case .feedback:
            return "decline"
        case .permissionSuggestions(let suggestions):
            if !pending.proposedExecpolicyAmendment.isEmpty, suggestionsContainSessionRule(suggestions) {
                return [
                    "acceptWithExecpolicyAmendment": [
                        "execpolicy_amendment": pending.proposedExecpolicyAmendment,
                    ],
                ]
            }
            return "acceptForSession"
        }
    }

    private func legacyApprovalDecision(pending: PendingRequest, resolution: LocalPermissionResolution) -> Any {
        switch resolution {
        case .decision(let decision):
            return decision == .allow ? "approved" : "denied"
        case .answers:
            return "approved"
        case .feedback:
            return "denied"
        case .permissionSuggestions(let suggestions):
            if !pending.proposedExecpolicyAmendment.isEmpty, suggestionsContainSessionRule(suggestions) {
                return [
                    "approved_execpolicy_amendment": [
                        "proposed_execpolicy_amendment": pending.proposedExecpolicyAmendment,
                    ],
                ]
            }
            return "approved_for_session"
        }
    }

    private func fileChangeDecision(resolution: LocalPermissionResolution) -> Any {
        switch resolution {
        case .decision(let decision):
            return decision == .allow ? "accept" : "decline"
        case .answers:
            return "accept"
        case .feedback:
            return "decline"
        case .permissionSuggestions:
            return "acceptForSession"
        }
    }

    private func permissionsApprovalResult(pending: PendingRequest, resolution: LocalPermissionResolution) -> [String: Any] {
        let requested = pending.requestedPermissions ?? [:]
        switch resolution {
        case .decision(let decision):
            if decision == .allow {
                return ["permissions": requested, "scope": "turn"]
            }
            return ["permissions": [:], "scope": "turn"]
        case .permissionSuggestions(let suggestions):
            let scope = suggestions.contains(where: { $0.destination == "session" }) ? "session" : "turn"
            return ["permissions": requested, "scope": scope]
        case .answers:
            return ["permissions": requested, "scope": "turn"]
        case .feedback:
            return ["permissions": [:], "scope": "turn"]
        }
    }

    private func requestUserInputResult(pending: PendingRequest, resolution: LocalPermissionResolution) -> [String: Any] {
        let answersByKey: [String: String]
        switch resolution {
        case .answers(let answers):
            answersByKey = answers
        case .feedback(let feedback):
            answersByKey = [pending.questions.first?.id ?? "feedback": feedback]
        case .decision(let decision):
            answersByKey = decision == .allow ? [:] : [:]
        case .permissionSuggestions:
            answersByKey = [:]
        }

        var mapped: [String: Any] = [:]
        var usedKeys = Set<String>()

        for question in pending.questions {
            let value = answersByKey[question.id] ?? answersByKey[question.prompt]
            guard let value, !value.isEmpty else { continue }
            mapped[question.id] = ["answers": [value]]
            usedKeys.insert(question.id)
            usedKeys.insert(question.prompt)
        }

        if mapped.isEmpty {
            for key in answersByKey.keys.sorted() {
                guard !usedKeys.contains(key),
                      let value = answersByKey[key],
                      !value.isEmpty else { continue }
                mapped[key] = ["answers": [value]]
            }
        }

        return ["answers": mapped]
    }

    private func mcpElicitationResult(resolution: LocalPermissionResolution) -> [String: Any] {
        switch resolution {
        case .decision(let decision):
            return ["action": decision == .allow ? "accept" : "decline"]
        case .answers(let answers):
            if let first = answers.values.first, !first.isEmpty {
                return ["action": "accept", "content": ["text": first]]
            }
            return ["action": "accept"]
        case .feedback(let feedback):
            let trimmed = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return ["action": "decline"]
            }
            return ["action": "accept", "content": ["text": trimmed]]
        case .permissionSuggestions:
            return ["action": "accept"]
        }
    }

    private func suggestionsContainSessionRule(_ suggestions: [PermissionSuggestion]) -> Bool {
        suggestions.contains(where: { suggestion in
            suggestion.type == "addRules" && suggestion.destination == "session"
        })
    }

    static func requestIdString(from raw: Any?) -> String? {
        switch raw {
        case let string as String:
            return string
        case let int as Int:
            return String(int)
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}

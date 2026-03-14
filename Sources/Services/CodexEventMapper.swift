import Foundation

struct CodexSessionContext {
    let sessionId: String
    var cwd: String?
    var source: String?
    var originator: String?
    var toolNamesByCallId: [String: String] = [:]

    var normalizedSource: String {
        let sourceValue = source?.lowercased() ?? ""
        let originatorValue = originator?.lowercased() ?? ""
        if sourceValue.contains("vscode") || sourceValue.contains("desktop") || originatorValue.contains("desktop") {
            return "codex-desktop"
        }
        if sourceValue == "cli"
            || sourceValue == "exec"
            || sourceValue.contains("codex-cli")
            || originatorValue.contains("codex_cli")
            || originatorValue.contains("codex_exec") {
            return "codex-cli"
        }
        return "codex"
    }

    func merged(with other: CodexSessionContext) -> CodexSessionContext {
        var mergedToolNames = toolNamesByCallId
        for (callId, toolName) in other.toolNamesByCallId {
            mergedToolNames[callId] = toolName
        }
        return CodexSessionContext(
            sessionId: sessionId,
            cwd: other.cwd ?? cwd,
            source: other.source ?? source,
            originator: other.originator ?? originator,
            toolNamesByCallId: mergedToolNames
        )
    }
}

struct CodexParseResult {
    var context: CodexSessionContext?
    var events: [ClaudeEvent] = []
}

enum CodexEventMapper {
    private static let sessionIdRegex = try! NSRegularExpression(
        pattern: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
    )
    private static let exitCodeRegex = try! NSRegularExpression(pattern: #"Exit code:\s*(-?\d+)"#)

    static func sessionId(fromFileURL fileURL: URL) -> String? {
        let filename = fileURL.lastPathComponent
        let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
        guard let match = sessionIdRegex.firstMatch(in: filename, range: range),
              let swiftRange = Range(match.range, in: filename) else {
            return nil
        }
        return String(filename[swiftRange])
    }

    static func parse(line: String, fileURL: URL, context: CodexSessionContext?) -> CodexParseResult {
        var result = CodexParseResult()

        guard let lineData = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let recordType = json["type"] as? String else {
            return result
        }

        let payload = json["payload"] as? [String: Any] ?? [:]
        let fallbackSessionId = sessionId(fromFileURL: fileURL)

        switch recordType {
        case "session_meta":
            guard let sessionId = (payload["id"] as? String) ?? fallbackSessionId else { return result }
            let discovered = CodexSessionContext(
                sessionId: sessionId,
                cwd: payload["cwd"] as? String,
                source: payload["source"] as? String,
                originator: payload["originator"] as? String
            )
            let mergedContext = merged(existing: context, update: discovered)
            result.context = mergedContext
            result.events = [
                ClaudeEvent(
                    hookEventName: HookEventType.sessionStart.rawValue,
                    sessionId: sessionId,
                    cwd: mergedContext.cwd,
                    source: mergedContext.normalizedSource,
                    model: payload["cli_version"] as? String
                ),
            ]
            return result

        case "turn_context":
            guard let sessionId = context?.sessionId ?? fallbackSessionId else { return result }
            let cwd = payload["cwd"] as? String
                ?? payload["working_dir"] as? String
                ?? payload["current_dir"] as? String
            let update = CodexSessionContext(
                sessionId: sessionId,
                cwd: cwd,
                source: nil,
                originator: nil
            )
            result.context = merged(existing: context, update: update)
            return result

        default:
            break
        }

        guard let sessionId = context?.sessionId ?? fallbackSessionId else { return result }
        var workingContext = context ?? CodexSessionContext(sessionId: sessionId, cwd: nil, source: nil, originator: nil)
        if let payloadCwd = payload["cwd"] as? String {
            let update = CodexSessionContext(sessionId: sessionId, cwd: payloadCwd, source: nil, originator: nil)
            workingContext = merged(existing: workingContext, update: update)
            result.context = workingContext
        }
        let source = workingContext.normalizedSource

        switch recordType {
        case "event_msg":
            guard let messageType = payload["type"] as? String else { return result }
            switch messageType {
            case "task_started":
                result.events = [
                    ClaudeEvent(
                        hookEventName: HookEventType.userPromptSubmit.rawValue,
                        sessionId: sessionId,
                        cwd: workingContext.cwd,
                        source: source,
                        taskId: payload["turn_id"] as? String
                    ),
                ]
            case "task_complete":
                let lastMessage = payload["last_agent_message"] as? String
                var events = [
                    ClaudeEvent(
                        hookEventName: HookEventType.stop.rawValue,
                        sessionId: sessionId,
                        cwd: workingContext.cwd,
                        source: source,
                        reason: "completed",
                        lastAssistantMessage: lastMessage
                    ),
                ]
                if !ClaudeEvent.looksLikeQuestionPrompt(lastMessage) {
                    events.append(
                        ClaudeEvent(
                            hookEventName: HookEventType.taskCompleted.rawValue,
                            sessionId: sessionId,
                            cwd: workingContext.cwd,
                            source: source,
                            taskId: payload["turn_id"] as? String,
                            taskSubject: codexTaskSubject(from: lastMessage)
                        )
                    )
                }
                result.events = events
            case "turn_aborted":
                result.events = [
                    ClaudeEvent(
                        hookEventName: HookEventType.stop.rawValue,
                        sessionId: sessionId,
                        cwd: workingContext.cwd,
                        source: source,
                        reason: payload["reason"] as? String ?? "interrupted"
                    ),
                ]
            case "request_user_input":
                let toolUseId = payload["call_id"] as? String
                var toolInput = payload
                toolInput.removeValue(forKey: "type")
                result.events = [
                    ClaudeEvent(
                        hookEventName: HookEventType.permissionRequest.rawValue,
                        sessionId: sessionId,
                        cwd: workingContext.cwd,
                        toolName: "AskUserQuestion",
                        toolInput: codableMap(toolInput),
                        toolUseId: toolUseId,
                        message: codexQuestionMessage(arguments: toolInput),
                        source: source
                    ),
                ]
            case "agent_message":
                guard let message = nonEmptyString(payload["message"]) else { return result }
                var events = [
                    ClaudeEvent(
                        hookEventName: HookEventType.notification.rawValue,
                        sessionId: sessionId,
                        cwd: workingContext.cwd,
                        message: message,
                        notificationType: "codex_agent_message",
                        source: source
                    ),
                ]
                if shouldSynthesizeQuestionPermission(message: message, phase: payload["phase"] as? String) {
                    events.append(
                        ClaudeEvent(
                            hookEventName: HookEventType.permissionRequest.rawValue,
                            sessionId: sessionId,
                            cwd: workingContext.cwd,
                            toolName: "AskUserQuestion",
                            toolInput: codableMap(codexQuestionToolInput(message: message)),
                            message: message,
                            source: source
                        )
                    )
                }
                result.events = events
            case "user_message":
                guard let message = nonEmptyString(payload["message"]) else { return result }
                result.events = [
                    ClaudeEvent(
                        hookEventName: HookEventType.notification.rawValue,
                        sessionId: sessionId,
                        cwd: workingContext.cwd,
                        message: message,
                        notificationType: "codex_user_message",
                        source: source
                    ),
                ]
            case "agent_reasoning":
                guard let message = nonEmptyString(payload["text"]) else { return result }
                result.events = [
                    ClaudeEvent(
                        hookEventName: HookEventType.notification.rawValue,
                        sessionId: sessionId,
                        cwd: workingContext.cwd,
                        message: message,
                        notificationType: "codex_agent_reasoning",
                        source: source
                    ),
                ]
            case "token_count":
                result.events = [
                    ClaudeEvent(
                        hookEventName: HookEventType.notification.rawValue,
                        sessionId: sessionId,
                        cwd: workingContext.cwd,
                        message: codexTokenCountMessage(payload: payload),
                        notificationType: "codex_token_count",
                        source: source
                    ),
                ]
            case "request_permissions":
                let toolUseId = payload["call_id"] as? String
                var toolInput = payload
                toolInput.removeValue(forKey: "type")
                result.events = [
                    ClaudeEvent(
                        hookEventName: HookEventType.permissionRequest.rawValue,
                        sessionId: sessionId,
                        cwd: workingContext.cwd,
                        toolName: "request_permissions",
                        toolInput: codableMap(toolInput),
                        toolUseId: toolUseId,
                        message: codexPermissionMessage(toolName: "request_permissions", arguments: toolInput),
                        source: source,
                        permissionSuggestions: codexPermissionSuggestions(
                            toolName: "request_permissions",
                            arguments: toolInput
                        )?.map(AnyCodable.init)
                    ),
                ]
            case "exec_command_begin":
                let toolUseId = payload["call_id"] as? String
                let toolInput = codexExecApprovalInput(payload: payload)
                result.events = [
                    ClaudeEvent(
                        hookEventName: HookEventType.preToolUse.rawValue,
                        sessionId: sessionId,
                        cwd: workingContext.cwd,
                        toolName: "exec_command",
                        toolInput: codableMap(toolInput),
                        toolUseId: toolUseId,
                        source: source
                    ),
                ]
            case "exec_command_end":
                let toolUseId = payload["call_id"] as? String
                let exitCode = payload["exit_code"] as? Int
                let statusValue = (payload["status"] as? String)?.lowercased()
                let isFailure = (exitCode.map { $0 != 0 } ?? false)
                    || (statusValue == "failed")
                    || (statusValue == "error")
                let hookName = isFailure ? HookEventType.postToolUseFailure.rawValue : HookEventType.postToolUse.rawValue
                var responsePayload = payload
                responsePayload.removeValue(forKey: "type")
                result.events = [
                    ClaudeEvent(
                        hookEventName: hookName,
                        sessionId: sessionId,
                        cwd: workingContext.cwd,
                        toolName: "exec_command",
                        toolResponse: codableMap(responsePayload),
                        toolUseId: toolUseId,
                        source: source
                    ),
                ]
            case "exec_approval_request":
                let toolUseId = payload["call_id"] as? String
                let toolInput = codexExecApprovalInput(payload: payload)
                result.events = [
                    ClaudeEvent(
                        hookEventName: HookEventType.preToolUse.rawValue,
                        sessionId: sessionId,
                        cwd: workingContext.cwd,
                        toolName: "exec_command",
                        toolInput: codableMap(toolInput),
                        toolUseId: toolUseId,
                        source: source
                    ),
                    ClaudeEvent(
                        hookEventName: HookEventType.permissionRequest.rawValue,
                        sessionId: sessionId,
                        cwd: workingContext.cwd,
                        toolName: "exec_command",
                        toolInput: codableMap(toolInput),
                        toolUseId: toolUseId,
                        message: codexPermissionMessage(toolName: "exec_command", arguments: toolInput),
                        source: source,
                        permissionSuggestions: codexPermissionSuggestions(
                            toolName: "exec_command",
                            arguments: toolInput
                        )?.map(AnyCodable.init)
                    ),
                ]
            case "mcp_tool_call_begin":
                let toolUseId = payload["call_id"] as? String
                let toolName = codexMcpToolName(payload: payload) ?? "mcp_tool"
                result.events = [
                    ClaudeEvent(
                        hookEventName: HookEventType.preToolUse.rawValue,
                        sessionId: sessionId,
                        cwd: workingContext.cwd,
                        toolName: toolName,
                        toolInput: codableMap(payload),
                        toolUseId: toolUseId,
                        source: source
                    ),
                ]
            case "mcp_tool_call_end":
                let toolUseId = payload["call_id"] as? String
                let toolName = codexMcpToolName(payload: payload)
                let isFailure = payload["result"] as? String != nil
                let hookName = isFailure ? HookEventType.postToolUseFailure.rawValue : HookEventType.postToolUse.rawValue
                var responsePayload = payload
                responsePayload.removeValue(forKey: "type")
                result.events = [
                    ClaudeEvent(
                        hookEventName: hookName,
                        sessionId: sessionId,
                        cwd: workingContext.cwd,
                        toolName: toolName,
                        toolResponse: codableMap(responsePayload),
                        toolUseId: toolUseId,
                        source: source
                    ),
                ]
            case "context_compacted":
                result.events = [
                    ClaudeEvent(
                        hookEventName: HookEventType.preCompact.rawValue,
                        sessionId: sessionId,
                        cwd: workingContext.cwd,
                        source: source,
                        reason: "context_compacted"
                    ),
                ]
            case "item_completed":
                result.events = mapItemCompletedEvent(
                    payload: payload,
                    sessionId: sessionId,
                    cwd: workingContext.cwd,
                    source: source
                )
            case "entered_review_mode", "exited_review_mode":
                result.events = [
                    ClaudeEvent(
                        hookEventName: HookEventType.configChange.rawValue,
                        sessionId: sessionId,
                        cwd: workingContext.cwd,
                        source: source,
                        reason: messageType
                    ),
                ]
            default:
                break
            }

        case "compacted":
            result.events = [
                ClaudeEvent(
                    hookEventName: HookEventType.preCompact.rawValue,
                    sessionId: sessionId,
                    cwd: workingContext.cwd,
                    source: source,
                    reason: "context_compacted"
                ),
            ]

        case "response_item":
            if let updatedContext = recordToolCallContext(payload: payload, context: workingContext) {
                workingContext = updatedContext
                result.context = workingContext
            }
            result.events = mapToolEvents(
                payload: payload,
                sessionId: sessionId,
                cwd: workingContext.cwd,
                source: source,
                context: workingContext
            )

        case "function_call":
            if let updatedContext = recordToolCallContext(payload: payload, context: workingContext) {
                workingContext = updatedContext
                result.context = workingContext
            }
            result.events = mapLegacyToolCall(
                payload: payload,
                sessionId: sessionId,
                cwd: workingContext.cwd,
                source: source
            )

        case "function_call_output":
            result.events = mapLegacyToolOutput(
                payload: payload,
                sessionId: sessionId,
                cwd: workingContext.cwd,
                source: source,
                context: workingContext
            )

        default:
            break
        }

        return result
    }

    private static func mapToolEvents(
        payload: [String: Any],
        sessionId: String,
        cwd: String?,
        source: String,
        context: CodexSessionContext
    ) -> [ClaudeEvent] {
        guard let payloadType = payload["type"] as? String else { return [] }

        switch payloadType {
        case "function_call", "custom_tool_call":
            let arguments = toolArguments(payload: payload, payloadType: payloadType)
            let toolName = payload["name"] as? String ?? "tool"
            let toolUseId = payload["call_id"] as? String ?? payload["id"] as? String
            var events: [ClaudeEvent] = [
                ClaudeEvent(
                    hookEventName: HookEventType.preToolUse.rawValue,
                    sessionId: sessionId,
                    cwd: cwd,
                    toolName: toolName,
                    toolInput: codableMap(arguments),
                    toolUseId: toolUseId,
                    source: source
                ),
            ]

            // Codex does not emit Claude-style PermissionRequest hooks.
            // When a tool call explicitly asks for escalated sandbox permissions,
            // synthesize a permission request so the existing mascot approval UX can react.
            if requiresEscalatedPermission(arguments) {
                events.append(
                    ClaudeEvent(
                        hookEventName: HookEventType.permissionRequest.rawValue,
                        sessionId: sessionId,
                        cwd: cwd,
                        toolName: toolName,
                        toolInput: codableMap(arguments),
                        toolUseId: toolUseId,
                        message: codexPermissionMessage(toolName: toolName, arguments: arguments),
                        source: source,
                        permissionSuggestions: codexPermissionSuggestions(
                            toolName: toolName,
                            arguments: arguments
                        )?.map(AnyCodable.init)
                    )
                )
            } else if isRequestUserInput(toolName: toolName, arguments: arguments) {
                events.append(
                    ClaudeEvent(
                        hookEventName: HookEventType.permissionRequest.rawValue,
                        sessionId: sessionId,
                        cwd: cwd,
                        toolName: "AskUserQuestion",
                        toolInput: codableMap(arguments),
                        toolUseId: toolUseId,
                        message: codexQuestionMessage(arguments: arguments),
                        source: source
                    )
                )
            }
            return events

        case "function_call_output", "custom_tool_call_output":
            let output = toolOutput(payload["output"])
            let hookName = isToolOutputFailure(payload: payload, output: output)
                ? HookEventType.postToolUseFailure.rawValue
                : HookEventType.postToolUse.rawValue
            let toolName = resolvedToolName(payload: payload, context: context)
            return [
                ClaudeEvent(
                    hookEventName: hookName,
                    sessionId: sessionId,
                    cwd: cwd,
                    toolName: toolName,
                    toolResponse: codableMap(output),
                    toolUseId: payload["call_id"] as? String ?? payload["id"] as? String,
                    source: source
                ),
            ]
        case "message":
            guard !shouldIgnoreResponseMessageNotification(payload: payload) else { return [] }
            guard let message = codexResponseMessageText(payload: payload) else { return [] }
            let role = payload["role"] as? String
            let notificationType = role == "assistant" ? "codex_agent_message" : "codex_message"
            return [
                ClaudeEvent(
                    hookEventName: HookEventType.notification.rawValue,
                    sessionId: sessionId,
                    cwd: cwd,
                    message: message,
                    notificationType: notificationType,
                    source: source
                ),
            ]
        case "reasoning":
            guard let summary = codexReasoningSummary(payload: payload) else { return [] }
            return [
                ClaudeEvent(
                    hookEventName: HookEventType.notification.rawValue,
                    sessionId: sessionId,
                    cwd: cwd,
                    message: summary,
                    notificationType: "codex_agent_reasoning",
                    source: source
                ),
            ]
        case "web_search_call":
            let toolUseId = payload["call_id"] as? String ?? payload["id"] as? String
            let status = (payload["status"] as? String)?.lowercased()
            let isFailure = status == "failed" || status == "error"
            let toolName = "web_search_call"
            var responsePayload = payload
            responsePayload.removeValue(forKey: "type")
            return [
                ClaudeEvent(
                    hookEventName: HookEventType.preToolUse.rawValue,
                    sessionId: sessionId,
                    cwd: cwd,
                    toolName: toolName,
                    toolInput: codableMap(payload),
                    toolUseId: toolUseId,
                    source: source
                ),
                ClaudeEvent(
                    hookEventName: isFailure ? HookEventType.postToolUseFailure.rawValue : HookEventType.postToolUse.rawValue,
                    sessionId: sessionId,
                    cwd: cwd,
                    toolName: toolName,
                    toolResponse: codableMap(responsePayload),
                    toolUseId: toolUseId,
                    source: source
                ),
            ]

        default:
            return []
        }
    }

    private static func mapLegacyToolCall(
        payload: [String: Any],
        sessionId: String,
        cwd: String?,
        source: String
    ) -> [ClaudeEvent] {
        let arguments = toolArguments(
            payload: payload,
            payloadType: payload["type"] as? String ?? "function_call"
        )
        let toolName = payload["name"] as? String ?? "tool"
        let toolUseId = payload["call_id"] as? String ?? payload["id"] as? String
        var events: [ClaudeEvent] = [
            ClaudeEvent(
                hookEventName: HookEventType.preToolUse.rawValue,
                sessionId: sessionId,
                cwd: cwd,
                toolName: toolName,
                toolInput: codableMap(arguments),
                toolUseId: toolUseId,
                source: source
            ),
        ]
        if requiresEscalatedPermission(arguments) {
            events.append(
                ClaudeEvent(
                    hookEventName: HookEventType.permissionRequest.rawValue,
                    sessionId: sessionId,
                    cwd: cwd,
                    toolName: toolName,
                    toolInput: codableMap(arguments),
                    toolUseId: toolUseId,
                    message: codexPermissionMessage(toolName: toolName, arguments: arguments),
                    source: source,
                    permissionSuggestions: codexPermissionSuggestions(
                        toolName: toolName,
                        arguments: arguments
                    )?.map(AnyCodable.init)
                )
            )
        } else if isRequestUserInput(toolName: toolName, arguments: arguments) {
            events.append(
                ClaudeEvent(
                    hookEventName: HookEventType.permissionRequest.rawValue,
                    sessionId: sessionId,
                    cwd: cwd,
                    toolName: "AskUserQuestion",
                    toolInput: codableMap(arguments),
                    toolUseId: toolUseId,
                    message: codexQuestionMessage(arguments: arguments),
                    source: source
                )
            )
        }
        return events
    }

    private static func mapLegacyToolOutput(
        payload: [String: Any],
        sessionId: String,
        cwd: String?,
        source: String,
        context: CodexSessionContext
    ) -> [ClaudeEvent] {
        let output = toolOutput(payload["output"])
        return [
            ClaudeEvent(
                hookEventName: isToolOutputFailure(payload: payload, output: output)
                    ? HookEventType.postToolUseFailure.rawValue
                    : HookEventType.postToolUse.rawValue,
                sessionId: sessionId,
                cwd: cwd,
                toolName: resolvedToolName(payload: payload, context: context),
                toolResponse: codableMap(output),
                toolUseId: payload["call_id"] as? String ?? payload["id"] as? String,
                source: source
            ),
        ]
    }

    private static func parseJSONObject(_ value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            return dict
        }
        if let string = value as? String,
           let data = string.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        return nil
    }

    private static func toolArguments(payload: [String: Any], payloadType: String) -> [String: Any] {
        if payloadType == "custom_tool_call",
           let input = parseJSONObject(payload["input"]) {
            return input
        }

        if let arguments = parseJSONObject(payload["arguments"]) {
            return arguments
        }

        if let input = parseJSONObject(payload["input"]) {
            return input
        }

        return [:]
    }

    private static func toolOutput(_ value: Any?) -> [String: Any]? {
        if let dict = parseJSONObject(value) {
            return dict
        }

        guard let string = value as? String, !string.isEmpty else { return nil }
        var output: [String: Any] = ["output": string]
        if let exitCode = exitCode(fromOutputText: string) {
            output["exit_code"] = exitCode
        }
        return output
    }

    private static func isToolOutputFailure(payload: [String: Any], output: [String: Any]?) -> Bool {
        let status = (payload["status"] as? String)?.lowercased()
        if status == "failed" || status == "error" {
            return true
        }

        if let exitCode = integerValue(payload["exit_code"]), exitCode != 0 {
            return true
        }

        if containsErrorPayload(payload["error"]) {
            return true
        }

        guard let output else { return false }
        if let exitCode = integerValue(output["exit_code"]), exitCode != 0 {
            return true
        }
        if containsErrorPayload(output["error"]) {
            return true
        }
        if let metadata = output["metadata"] as? [String: Any] {
            if let exitCode = integerValue(metadata["exit_code"]), exitCode != 0 {
                return true
            }
            if containsErrorPayload(metadata["error"]) {
                return true
            }
        }
        return false
    }

    private static func recordToolCallContext(payload: [String: Any], context: CodexSessionContext) -> CodexSessionContext? {
        guard let toolUseId = payload["call_id"] as? String ?? payload["id"] as? String,
              let toolName = payload["name"] as? String,
              !toolName.isEmpty else {
            return nil
        }
        var updated = context
        updated.toolNamesByCallId[toolUseId] = toolName
        return updated
    }

    private static func resolvedToolName(payload: [String: Any], context: CodexSessionContext) -> String? {
        if let toolName = payload["name"] as? String, !toolName.isEmpty {
            return toolName
        }
        if let toolUseId = payload["call_id"] as? String ?? payload["id"] as? String {
            return context.toolNamesByCallId[toolUseId]
        }
        return nil
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func containsErrorPayload(_ value: Any?) -> Bool {
        if let string = value as? String {
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let dict = value as? [String: Any] {
            return !dict.isEmpty
        }
        if let array = value as? [Any] {
            return !array.isEmpty
        }
        return false
    }

    private static func exitCode(fromOutputText text: String) -> Int? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = exitCodeRegex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let codeRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[codeRange])
    }

    private static func codableMap(_ dict: [String: Any]?) -> [String: AnyCodable]? {
        guard let dict else { return nil }
        return dict.mapValues(AnyCodable.init)
    }

    private static func merged(existing: CodexSessionContext?, update: CodexSessionContext) -> CodexSessionContext {
        guard let existing else { return update }
        guard existing.sessionId == update.sessionId else { return update }
        return existing.merged(with: update)
    }

    private static func requiresEscalatedPermission(_ arguments: [String: Any]) -> Bool {
        guard let rawValue = arguments["sandbox_permissions"] as? String else { return false }
        return rawValue.lowercased() == "require_escalated"
    }

    private static func shouldSynthesizeQuestionPermission(message: String, phase: String?) -> Bool {
        guard let phase = phase?.lowercased(), phase == "commentary" else { return false }
        return ClaudeEvent.looksLikeQuestionPrompt(message)
    }

    private static func isRequestUserInput(toolName: String, arguments: [String: Any]) -> Bool {
        guard toolName == "request_user_input" else { return false }
        return arguments["questions"] != nil
    }

    private static func codexQuestionToolInput(message: String) -> [String: Any] {
        [
            "questions": [
                [
                    "id": "response",
                    "question": message,
                    "options": [],
                ],
            ],
        ]
    }

    private static func codexPermissionMessage(toolName: String, arguments: [String: Any]) -> String {
        if let justification = arguments["justification"] as? String, !justification.isEmpty {
            return justification
        }
        if let reason = arguments["reason"] as? String, !reason.isEmpty {
            return reason
        }
        if let command = arguments["cmd"] as? String, !command.isEmpty {
            return "Codex needs approval to run: \(command)"
        }
        if let command = arguments["command"] as? [String], !command.isEmpty {
            return "Codex needs approval to run: \(command.joined(separator: " "))"
        }
        return "Codex needs approval to run \(toolName)"
    }

    private static func codexQuestionMessage(arguments: [String: Any]) -> String? {
        if let questions = arguments["questions"] as? [[String: Any]],
           let first = questions.first,
           let question = first["question"] as? String,
           !question.isEmpty {
            return question
        }
        if let questions = arguments["questions"] as? [Any] {
            for element in questions {
                if let question = (element as? [String: Any])?["question"] as? String,
                   !question.isEmpty {
                    return question
                }
            }
        }
        return "Codex requested your input"
    }

    private static func codexPermissionSuggestions(
        toolName: String,
        arguments: [String: Any]
    ) -> [[String: Any]]? {
        guard let prefixRule = codexPrefixRule(arguments["prefix_rule"]),
              !prefixRule.isEmpty else {
            return nil
        }

        return [[
            "type": "addRules",
            "destination": "session",
            "behavior": "allow",
            "rules": [[
                "toolName": toolName,
                "ruleContent": prefixRule.joined(separator: " "),
            ]],
        ]]
    }

    private static func codexExecApprovalInput(payload: [String: Any]) -> [String: Any] {
        var input = payload
        input.removeValue(forKey: "type")
        if let command = payload["command"] as? [String], !command.isEmpty {
            input["cmd"] = command.joined(separator: " ")
        }
        if input["sandbox_permissions"] == nil {
            input["sandbox_permissions"] = "require_escalated"
        }
        return input
    }

    private static func codexPrefixRule(_ value: Any?) -> [String]? {
        if let values = value as? [String], !values.isEmpty {
            return values
        }
        if let values = value as? [Any] {
            let strings = values.compactMap { $0 as? String }.filter { !$0.isEmpty }
            return strings.isEmpty ? nil : strings
        }
        return nil
    }

    private static func codexMcpToolName(payload: [String: Any]) -> String? {
        guard let invocation = payload["invocation"] as? [String: Any] else { return nil }
        if let name = invocation["tool_name"] as? String, !name.isEmpty { return name }
        if let name = invocation["tool"] as? String, !name.isEmpty { return name }
        if let name = invocation["name"] as? String, !name.isEmpty { return name }
        return nil
    }

    private static func codexTokenCountMessage(payload: [String: Any]) -> String {
        if let limits = payload["rate_limits"] as? [String: Any] {
            var parts: [String] = []
            if let primary = limits["primary"] as? [String: Any],
               let percent = primary["used_percent"] {
                parts.append("primary \(percent)%")
            }
            if let secondary = limits["secondary"] as? [String: Any],
               let percent = secondary["used_percent"] {
                parts.append("secondary \(percent)%")
            }
            if !parts.isEmpty {
                return "Token usage: " + parts.joined(separator: ", ")
            }
        }

        guard let info = payload["info"] as? [String: Any],
              let total = info["total_token_usage"] as? [String: Any] else {
            return "Codex token usage updated"
        }

        var parts: [String] = []
        if let totalTokens = integerValue(total["total_tokens"]) {
            parts.append("total \(formattedTokenCount(totalTokens))")
        }
        if let inputTokens = integerValue(total["input_tokens"]) {
            var inputPart = "input \(formattedTokenCount(inputTokens))"
            if let cachedInput = integerValue(total["cached_input_tokens"]), cachedInput > 0 {
                inputPart += " (+ \(formattedTokenCount(cachedInput)) cached)"
            }
            parts.append(inputPart)
        }
        if let outputTokens = integerValue(total["output_tokens"]) {
            var outputPart = "output \(formattedTokenCount(outputTokens))"
            if let reasoningTokens = integerValue(total["reasoning_output_tokens"]), reasoningTokens > 0 {
                outputPart += " (reasoning \(formattedTokenCount(reasoningTokens)))"
            }
            parts.append(outputPart)
        }

        guard !parts.isEmpty else { return "Codex token usage updated" }
        return "Token usage: " + parts.joined(separator: ", ")
    }

    private static func codexResponseMessageText(payload: [String: Any]) -> String? {
        if let content = payload["content"] as? [[String: Any]] {
            for item in content {
                if let text = item["text"] as? String, !text.isEmpty {
                    return text
                }
            }
        }
        if let content = payload["content"] as? [Any] {
            for item in content {
                if let dict = item as? [String: Any],
                   let text = dict["text"] as? String,
                   !text.isEmpty {
                    return text
                }
            }
        }
        return payload["message"] as? String
    }

    private static func shouldIgnoreResponseMessageNotification(payload: [String: Any]) -> Bool {
        let role = (payload["role"] as? String)?.lowercased() ?? ""
        switch role {
        case "developer", "system", "user":
            return true
        case "assistant":
            let phase = (payload["phase"] as? String)?.lowercased()
            return phase == "commentary" || phase == "final_answer"
        default:
            return false
        }
    }

    private static func codexReasoningSummary(payload: [String: Any]) -> String? {
        if let summary = payload["summary"] as? [[String: Any]] {
            for item in summary {
                if let text = item["text"] as? String, !text.isEmpty {
                    return text
                }
            }
            for item in summary {
                if let text = item["summary_text"] as? String, !text.isEmpty {
                    return text
                }
            }
        }
        if let summary = payload["summary"] as? [Any] {
            for item in summary {
                guard let dict = item as? [String: Any] else { continue }
                if let text = dict["text"] as? String, !text.isEmpty {
                    return text
                }
                if let text = dict["summary_text"] as? String, !text.isEmpty {
                    return text
                }
            }
        }
        return nil
    }

    private static func mapItemCompletedEvent(
        payload: [String: Any],
        sessionId: String,
        cwd: String?,
        source: String
    ) -> [ClaudeEvent] {
        let taskId = payload["turn_id"] as? String
        var subject: String?
        if let item = payload["item"] as? [String: Any] {
            if let text = item["text"] as? String {
                subject = codexTaskSubject(from: text)
            } else if let itemType = item["type"] as? String, !itemType.isEmpty {
                subject = itemType
            }
        }

        return [
            ClaudeEvent(
                hookEventName: HookEventType.taskCompleted.rawValue,
                sessionId: sessionId,
                cwd: cwd,
                source: source,
                taskId: taskId,
                taskSubject: subject
            ),
        ]
    }

    private static func codexTaskSubject(from text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.components(separatedBy: .newlines).first
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func formattedTokenCount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

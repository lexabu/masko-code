import Foundation

struct CodexSessionContext {
    let sessionId: String
    var cwd: String?
    var source: String?
    var originator: String?

    var normalizedSource: String {
        let sourceValue = source?.lowercased() ?? ""
        let originatorValue = originator?.lowercased() ?? ""
        if sourceValue.contains("vscode") || sourceValue.contains("desktop") || originatorValue.contains("desktop") {
            return "codex-desktop"
        }
        if sourceValue == "cli" || sourceValue.contains("codex-cli") || originatorValue.contains("codex_cli") {
            return "codex-cli"
        }
        return "codex"
    }

    func merged(with other: CodexSessionContext) -> CodexSessionContext {
        CodexSessionContext(
            sessionId: sessionId,
            cwd: other.cwd ?? cwd,
            source: other.source ?? source,
            originator: other.originator ?? originator
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
                result.events = [
                    ClaudeEvent(
                        hookEventName: HookEventType.stop.rawValue,
                        sessionId: sessionId,
                        cwd: workingContext.cwd,
                        source: source,
                        reason: "completed",
                        lastAssistantMessage: payload["last_agent_message"] as? String
                    ),
                ]
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
            result.events = mapToolEvents(
                payload: payload,
                sessionId: sessionId,
                cwd: workingContext.cwd,
                source: source
            )

        case "function_call":
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
                source: source
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
        source: String
    ) -> [ClaudeEvent] {
        guard let payloadType = payload["type"] as? String else { return [] }

        switch payloadType {
        case "function_call", "custom_tool_call":
            let arguments = parseJSONObject(payload["arguments"]) ?? [:]
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
                        source: source
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
            let output = parseJSONObject(payload["output"])
            let hookName: String
            if (payload["status"] as? String)?.lowercased() == "failed" {
                hookName = HookEventType.postToolUseFailure.rawValue
            } else {
                hookName = HookEventType.postToolUse.rawValue
            }
            return [
                ClaudeEvent(
                    hookEventName: hookName,
                    sessionId: sessionId,
                    cwd: cwd,
                    toolResponse: codableMap(output),
                    toolUseId: payload["call_id"] as? String ?? payload["id"] as? String,
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
        let arguments = parseJSONObject(payload["arguments"]) ?? [:]
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
                    source: source
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
        source: String
    ) -> [ClaudeEvent] {
        let output = parseJSONObject(payload["output"])
        return [
            ClaudeEvent(
                hookEventName: HookEventType.postToolUse.rawValue,
                sessionId: sessionId,
                cwd: cwd,
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

    private static func isRequestUserInput(toolName: String, arguments: [String: Any]) -> Bool {
        guard toolName == "request_user_input" else { return false }
        return arguments["questions"] != nil
    }

    private static func codexPermissionMessage(toolName: String, arguments: [String: Any]) -> String {
        if let justification = arguments["justification"] as? String, !justification.isEmpty {
            return justification
        }
        if let command = arguments["cmd"] as? String, !command.isEmpty {
            return "Codex needs approval to run: \(command)"
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
}

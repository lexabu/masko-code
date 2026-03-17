import SwiftUI

/// Fullscreen-style expanded view for reading permission/plan content.
/// Triggered by Cmd+P or the expand button on permission prompts.
/// Renders differently for each permission type: ExitPlanMode, AskUserQuestion, standard.
struct ExpandedPermissionView: View {
    let permission: PendingPermission
    let onDecision: (PermissionDecision) -> Void
    let onFeedback: ((String) -> Void)?
    let onAllowWithPermissions: (([PermissionSuggestion]) -> Void)?
    let onAnswers: (([String: String]) -> Void)?
    let onLater: () -> Void
    let onClose: () -> Void

    @Environment(PendingPermissionStore.self) private var pendingPermissionStore
    @Environment(SessionStore.self) private var sessionStore
    @Environment(GlobalHotkeyManager.self) private var hotkeyManager

    // Plan state
    @State private var selectedOption = 1
    @State private var feedbackText = ""
    @FocusState private var feedbackFocused: Bool

    // Question state
    @State private var selections: [String: String] = [:]
    @State private var multiSelections: [String: Set<String>] = [:]
    @State private var customInputs: [String: String] = [:]
    @State private var usingCustom: Set<String> = []
    @State private var currentQuestionIndex: Int = 0
    @FocusState private var otherFieldFocused: String?

    private var isPlan: Bool { permission.event.toolName == "ExitPlanMode" }
    private var isQuestion: Bool { permission.parsedQuestions != nil && !(permission.parsedQuestions ?? []).isEmpty }
    private var questions: [ParsedQuestion] { permission.parsedQuestions ?? [] }
    private var showShortcuts: Bool { hotkeyManager.isCmdHeld }

    private var title: String {
        if isPlan { return "Plan Ready" }
        if isQuestion { return "Question" }
        return permission.toolName
    }

    private var icon: String {
        if isPlan { return "doc.text.fill" }
        if isQuestion { return "questionmark.circle.fill" }
        return "shield.checkered"
    }

    private var projectName: String? {
        guard let sessionId = permission.event.sessionId,
              let session = sessionStore.sessions.first(where: { $0.id == sessionId }) else { return nil }
        return session.projectName
    }

    private let planOptions = [
        "Yes, clear context and auto-accept edits",
        "Yes, auto-accept edits",
        "Yes, manually approve edits",
        "Tell Claude what to change",
    ]

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider()

            // Content area
            ScrollView(.vertical, showsIndicators: true) {
                if isPlan {
                    planContent
                } else if isQuestion {
                    questionContent
                } else {
                    standardContent
                }
            }
            .background(Color(red: 250/255, green: 249/255, blue: 247/255))

            Divider()

            // Action bar
            VStack(spacing: 12) {
                if isPlan {
                    planActions
                } else if isQuestion {
                    questionActions
                } else {
                    standardActions
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(Color.white)
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: Color.black.opacity(0.15), radius: 20, x: 0, y: 8)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(red: 249/255, green: 93/255, blue: 2/255))
                Text(title)
                    .font(Constants.heading(size: 15, weight: .bold))
                    .foregroundStyle(Color(red: 35/255, green: 17/255, blue: 60/255))
            }

            if let project = projectName {
                Text(project)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.4))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.05))
                    .clipShape(Capsule())
            }

            Spacer()

            // Terminal button
            HStack(spacing: 3) {
                Button {
                    focusTerminal(
                        pid: permission.event.terminalPid,
                        shellPid: permission.event.shellPid,
                        projectDir: permission.event.cwd,
                        sessionId: permission.event.sessionId,
                        sessions: sessionStore.sessions
                    )
                } label: {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.3))
                }
                .buttonStyle(.plain)
                .help("Open terminal")

                if showShortcuts { ActionBadge(label: "⌘M") }
            }

            // Later button
            HStack(spacing: 3) {
                Button { onLater() } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.3))
                }
                .buttonStyle(.plain)
                .help("Handle later")

                if showShortcuts { ActionBadge(label: "⌘L") }
            }

            // Close button
            HStack(spacing: 3) {
                Button { onClose() } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.3))
                }
                .buttonStyle(.plain)
                .help("Close expanded view")

                if showShortcuts { ActionBadge(label: "⌘P") }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color.white)
    }

    // MARK: - Content Views

    private var planContent: some View {
        let content = permission.planFileContent ?? "Plan file not found"
        return markdownText(content)
            .font(.system(size: 14))
            .foregroundStyle(Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.85))
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
    }

    private var questionContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(questions.enumerated()), id: \.offset) { qIdx, question in
                expandedQuestionView(question, questionIndex: qIdx)
            }
        }
        .padding(24)
    }

    private var standardContent: some View {
        Text(permission.fullToolInputText)
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.85))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
    }

    // MARK: - Question Views

    @ViewBuilder
    private func expandedQuestionView(_ question: ParsedQuestion, questionIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header = question.header {
                Text(header)
                    .font(Constants.heading(size: 11, weight: .bold))
                    .foregroundStyle(Color(red: 249/255, green: 93/255, blue: 2/255))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .overlay(Capsule().stroke(Color(red: 249/255, green: 93/255, blue: 2/255).opacity(0.25), lineWidth: 1))
            }

            markdownText(question.question)
                .font(Constants.body(size: 14, weight: .medium))
                .foregroundStyle(Color(red: 35/255, green: 17/255, blue: 60/255))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { idx, option in
                    expandedOptionRow(question: question, option: option, index: idx, questionIndex: questionIndex)
                }
                expandedOtherRow(question: question, questionIndex: questionIndex)
            }
        }
    }

    @ViewBuilder
    private func expandedOptionRow(question: ParsedQuestion, option: ParsedOption, index: Int, questionIndex: Int) -> some View {
        let isMulti = question.multiSelect
        let isSelected: Bool = {
            guard !usingCustom.contains(question.question) else { return false }
            if isMulti { return multiSelections[question.question]?.contains(option.label) == true }
            return selections[question.question] == option.label
        }()

        Button {
            currentQuestionIndex = questionIndex
            usingCustom.remove(question.question)
            if isMulti {
                var set = multiSelections[question.question] ?? []
                if set.contains(option.label) { set.remove(option.label) } else { set.insert(option.label) }
                multiSelections[question.question] = set
            } else {
                selections[question.question] = option.label
                if questionIndex + 1 < questions.count {
                    currentQuestionIndex = questionIndex + 1
                }
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isMulti
                    ? (isSelected ? "checkmark.square.fill" : "square")
                    : (isSelected ? "checkmark.circle.fill" : "circle"))
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected
                        ? Color(red: 249/255, green: 93/255, blue: 2/255)
                        : Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.2))
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    markdownText(option.label)
                        .font(Constants.body(size: 13, weight: .medium))
                        .foregroundStyle(Color(red: 35/255, green: 17/255, blue: 60/255))
                        .fixedSize(horizontal: false, vertical: true)

                    if let desc = option.description, !desc.isEmpty {
                        markdownText(desc)
                            .font(Constants.body(size: 11))
                            .foregroundStyle(Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)

                if showShortcuts {
                    ActionBadge(label: "⌘\(index + 1)")
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(isSelected
                ? Color(red: 249/255, green: 93/255, blue: 2/255).opacity(0.06)
                : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func expandedOtherRow(question: ParsedQuestion, questionIndex: Int) -> some View {
        let isCustom = usingCustom.contains(question.question)
        let otherIndex = question.options.count

        VStack(alignment: .leading, spacing: 4) {
            Button {
                currentQuestionIndex = questionIndex
                usingCustom.insert(question.question)
                selections.removeValue(forKey: question.question)
                otherFieldFocused = question.question
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isCustom ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(isCustom
                            ? Color(red: 249/255, green: 93/255, blue: 2/255)
                            : Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.2))
                        .frame(width: 16)

                    Text("Other")
                        .font(Constants.body(size: 13, weight: .medium))
                        .foregroundStyle(Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.55))

                    Spacer(minLength: 0)

                    if showShortcuts {
                        ActionBadge(label: "⌘\(otherIndex + 1)")
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(isCustom
                    ? Color(red: 249/255, green: 93/255, blue: 2/255).opacity(0.06)
                    : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            if isCustom {
                TextField("Type your answer...", text: Binding(
                    get: { customInputs[question.question] ?? "" },
                    set: { customInputs[question.question] = $0 }
                ))
                .focused($otherFieldFocused, equals: question.question)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color(red: 35/255, green: 17/255, blue: 60/255))
                .padding(8)
                .background(Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.leading, 28)
            }
        }
    }

    // MARK: - Question Actions

    private var allAnswered: Bool {
        questions.allSatisfy { q in
            if usingCustom.contains(q.question) { return !(customInputs[q.question] ?? "").isEmpty }
            if q.multiSelect { return !(multiSelections[q.question] ?? []).isEmpty }
            return selections[q.question] != nil
        }
    }

    private func submitAnswers() {
        var answers: [String: String] = [:]
        for q in questions {
            if usingCustom.contains(q.question) {
                answers[q.question] = customInputs[q.question] ?? ""
            } else if q.multiSelect {
                answers[q.question] = (multiSelections[q.question] ?? []).sorted().joined(separator: ", ")
            } else {
                answers[q.question] = selections[q.question] ?? ""
            }
        }
        onAnswers?(answers)
        onClose()
    }

    private var questionActions: some View {
        HStack(spacing: 10) {
            Text("⌘P close  ·  ⌘⎋ skip  ·  ⌘↵ submit")
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .foregroundStyle(Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.35))

            Spacer()

            Button {
                onDecision(.deny)
                onClose()
            } label: {
                HStack(spacing: 5) {
                    Text("Skip")
                        .font(Constants.heading(size: 13, weight: .semibold))
                    if showShortcuts { ActionBadge(label: "⌘⎋") }
                }
                .foregroundStyle(Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.5))
                .padding(.vertical, 8)
                .padding(.horizontal, 20)
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: .command)

            Button { submitAnswers() } label: {
                HStack(spacing: 5) {
                    Text("Submit")
                        .font(Constants.heading(size: 13, weight: .semibold))
                    if showShortcuts { ActionBadge(label: "⌘↵") }
                }
                .foregroundStyle(.white)
                .padding(.vertical, 8)
                .padding(.horizontal, 20)
                .background(allAnswered
                    ? Color(red: 249/255, green: 93/255, blue: 2/255)
                    : Color.gray.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!allAnswered)
        }
        .animation(.easeInOut(duration: 0.15), value: showShortcuts)
    }

    // MARK: - Plan Actions

    private var planActions: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                ForEach(Array(planOptions.enumerated()), id: \.offset) { idx, label in
                    Button {
                        selectedOption = idx
                        if idx == 3 { feedbackFocused = true }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: selectedOption == idx ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 12))
                                .foregroundStyle(selectedOption == idx
                                    ? Color(red: 249/255, green: 93/255, blue: 2/255)
                                    : Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.2))
                            Text(label)
                                .font(Constants.body(size: 12, weight: .medium))
                                .foregroundStyle(Color(red: 35/255, green: 17/255, blue: 60/255))
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity)
                        .background(selectedOption == idx
                            ? Color(red: 249/255, green: 93/255, blue: 2/255).opacity(0.06)
                            : Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.02))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    if idx < planOptions.count - 1 {
                        Spacer().frame(width: 6)
                    }
                }
            }

            if selectedOption == 3 {
                TextEditor(text: $feedbackText)
                    .focused($feedbackFocused)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 35/255, green: 17/255, blue: 60/255))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 60, maxHeight: 120)
                    .background(Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(red: 249/255, green: 93/255, blue: 2/255).opacity(0.2), lineWidth: 1)
                    )
                    .overlay(alignment: .topLeading) {
                        if feedbackText.isEmpty {
                            Text("Tell Claude what to change...")
                                .font(.system(size: 13))
                                .foregroundStyle(Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.3))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .allowsHitTesting(false)
                        }
                    }
            }

            actionButtons
        }
    }

    // MARK: - Standard Actions

    private var standardActions: some View {
        VStack(spacing: 10) {
            if !permission.permissionSuggestions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(permission.permissionSuggestions.enumerated()), id: \.element.id) { _, suggestion in
                        Button {
                            onAllowWithPermissions?([suggestion])
                            onClose()
                        } label: {
                            Text(suggestion.displayLabel)
                                .font(Constants.body(size: 12, weight: .medium))
                                .foregroundStyle(Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.5))
                                .padding(.vertical, 6)
                                .padding(.horizontal, 12)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.12), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
            }

            actionButtons
        }
    }

    // MARK: - Shared Action Buttons (Plan + Standard)

    private func performApprove() {
        if isPlan {
            if selectedOption == 3 && !feedbackText.isEmpty {
                onFeedback?(feedbackText)
            } else if selectedOption <= 1 {
                let autoAccept = [
                    PermissionSuggestion(type: "setMode", destination: "session", behavior: nil, rules: nil, mode: "acceptEdits"),
                ]
                onAllowWithPermissions?(autoAccept)
            } else {
                onDecision(.allow)
            }
        } else {
            onDecision(.allow)
        }
        onClose()
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Text("⌘P close  ·  ⌘⎋ deny  ·  ⌘↵ approve")
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .foregroundStyle(Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.35))

            Spacer()

            Button {
                onDecision(.deny)
                onClose()
            } label: {
                HStack(spacing: 5) {
                    Text("Deny")
                        .font(Constants.heading(size: 13, weight: .semibold))
                    if showShortcuts { ActionBadge(label: "⌘⎋") }
                }
                .foregroundStyle(Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.5))
                .padding(.vertical, 8)
                .padding(.horizontal, 20)
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: .command)

            Button { performApprove() } label: {
                HStack(spacing: 5) {
                    Text(isPlan ? "Approve" : "Allow")
                        .font(Constants.heading(size: 13, weight: .semibold))
                    if showShortcuts { ActionBadge(label: "⌘↵") }
                }
                .foregroundStyle(.white)
                .padding(.vertical, 8)
                .padding(.horizontal, 20)
                .background(isPlan && selectedOption == 3 && feedbackText.isEmpty
                    ? Color.gray.opacity(0.3)
                    : Color(red: 249/255, green: 93/255, blue: 2/255))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(isPlan && selectedOption == 3 && feedbackText.isEmpty)
        }
        .animation(.easeInOut(duration: 0.15), value: showShortcuts)
    }
}

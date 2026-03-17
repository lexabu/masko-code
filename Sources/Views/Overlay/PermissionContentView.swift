import MarkdownUI
import SwiftUI

/// Unified permission content view that renders in either compact (speech bubble)
/// or expanded (fullscreen panel) mode. Handles all 3 permission types:
/// ExitPlanMode (plan), AskUserQuestion, and standard permissions.
///
/// State is shared via `PendingPermissionStore.interactionState(for:)` so
/// selections and feedback survive expand/collapse transitions.
struct PermissionContentView: View {
    let permission: PendingPermission
    let mode: PermissionDisplayMode
    let onDecision: (PermissionDecision) -> Void
    let onAnswers: (([String: String]) -> Void)?
    let onFeedback: ((String) -> Void)?
    let onAllowWithPermissions: (([PermissionSuggestion]) -> Void)?
    let onLater: () -> Void
    let onToggleMode: () -> Void
    var showShortcuts: Bool = false

    @Environment(PendingPermissionStore.self) private var store
    @Environment(GlobalHotkeyManager.self) private var hotkeyManager
    @Environment(SessionStore.self) private var sessionStore

    @FocusState private var feedbackFocused: Bool
    @FocusState private var otherFieldFocused: String?

    private var state: PermissionInteractionState { store.interactionState(for: permission.id) }

    private var isPlan: Bool { permission.event.toolName == "ExitPlanMode" }
    private var isQuestion: Bool { !(permission.parsedQuestions ?? []).isEmpty }
    private var questions: [ParsedQuestion] { permission.parsedQuestions ?? [] }

    private var isExpanded: Bool { mode == .expanded }

    // Sizing
    private var headerFont: CGFloat { isExpanded ? 15 : 11 }
    private var bodyFont: CGFloat { isExpanded ? 14 : 11 }
    private var codeFont: CGFloat { isExpanded ? 13 : 10 }
    private var iconFont: CGFloat { isExpanded ? 14 : 11 }
    private var buttonFont: CGFloat { isExpanded ? 13 : 11 }
    private var optionFont: CGFloat { isExpanded ? 13 : 11 }
    private var hintFont: CGFloat { 8 }
    private var outerPadding: CGFloat { isExpanded ? 24 : 8 }
    private var innerSpacing: CGFloat { isExpanded ? 12 : 5 }
    private var buttonPaddingH: CGFloat { isExpanded ? 20 : 0 }
    private var buttonPaddingV: CGFloat { isExpanded ? 8 : 4 }
    private var contentMaxHeight: CGFloat? { isExpanded ? nil : (isPlan ? 120 : 200) }

    var body: some View {
        Group {
            if isExpanded {
                expandedLayout
            } else {
                compactLayout
            }
        }
        .onChange(of: hotkeyManager.selectedButtonIndex) { _, newIdx in
            guard showShortcuts || isExpanded, let idx = newIdx else { return }
            handleShortcutSelection(idx)
        }
        .onChange(of: hotkeyManager.confirmTrigger) { _, _ in
            guard showShortcuts || isExpanded else { return }
            handleShortcutConfirm()
        }
    }

    // MARK: - Layouts

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: innerSpacing) {
            headerSection
            contentSection
            actionsSection
            ShortcutHintBar()
        }
    }

    private var expandedLayout: some View {
        VStack(spacing: 0) {
            headerSection
                .padding(.horizontal, outerPadding)
                .padding(.vertical, 16)
                .background(Color.white)

            Divider()

            ScrollView(.vertical, showsIndicators: true) {
                contentSection
                    .padding(outerPadding)
            }
            .background(OverlayStyle.codeBg)

            Divider()

            actionsSection
                .padding(.horizontal, outerPadding)
                .padding(.vertical, 16)
                .background(Color.white)
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: Color.black.opacity(0.15), radius: 20, x: 0, y: 8)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            // Title
            HStack(spacing: isExpanded ? 8 : 4) {
                Image(systemName: titleIcon)
                    .font(.system(size: iconFont))
                    .foregroundStyle(OverlayStyle.orange)
                Text(titleText)
                    .font(Constants.heading(size: headerFont, weight: .bold))
                    .foregroundStyle(OverlayStyle.textPrimary)
            }

            if isExpanded, let project = projectName {
                Text(project)
                    .font(.system(size: 12))
                    .foregroundStyle(OverlayStyle.textPrimary.opacity(0.4))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(OverlayStyle.textPrimary.opacity(0.05))
                    .clipShape(Capsule())
            }

            Spacer()

            // Terminal button
            headerButton(icon: "terminal.fill", badge: "⌘M", help: "Open terminal") {
                focusTerminal(
                    pid: permission.event.terminalPid,
                    shellPid: permission.event.shellPid,
                    projectDir: permission.event.cwd,
                    sessionId: permission.event.sessionId,
                    sessions: sessionStore.sessions
                )
            }

            // Later button
            headerButton(icon: "clock.arrow.circlepath", badge: "⌘L", help: "Handle later") {
                onLater()
            }

            // Expand/collapse button
            headerButton(
                icon: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                badge: "⌘P",
                help: isExpanded ? "Close expanded view" : "Expand"
            ) {
                onToggleMode()
            }
        }
    }

    @ViewBuilder
    private func headerButton(icon: String, badge: String, help: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 3) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: isExpanded ? 11 : 10))
                    .foregroundStyle(OverlayStyle.textHint)
            }
            .buttonStyle(.plain)
            .help(help)

            if showShortcuts || (isExpanded && hotkeyManager.isCmdHeld) {
                ActionBadge(label: badge)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentSection: some View {
        if isPlan {
            planContentView
        } else if isQuestion {
            questionContentView
        } else {
            standardContentView
        }
    }

    // MARK: Plan Content

    @ViewBuilder
    private var planContentView: some View {
        if let content = permission.planFileContent {
            if isExpanded {
                Markdown(content)
                    .markdownTextStyle {
                        FontSize(bodyFont)
                        ForegroundColor(Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.85))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if state.isContentExpanded {
                ScrollView(.vertical, showsIndicators: true) {
                    Markdown(content)
                        .markdownTextStyle {
                            FontSize(codeFont)
                            ForegroundColor(Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.85))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(5)
                .background(OverlayStyle.codeBg)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(OverlayStyle.codeBorder, lineWidth: 1))
                .contentShape(Rectangle())
                .onTapGesture { state.isContentExpanded = false }

                Text("tap to collapse")
                    .font(.system(size: 9))
                    .foregroundStyle(OverlayStyle.textHint)
            } else {
                let preview = content.split(separator: "\n", omittingEmptySubsequences: false)
                    .prefix(4)
                    .joined(separator: "\n")

                Markdown(preview)
                    .markdownTextStyle {
                        FontSize(codeFont)
                        ForegroundColor(Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.75))
                    }
                    .lineLimit(4)
                    .padding(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(OverlayStyle.codeBg)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(OverlayStyle.codeBorder, lineWidth: 1))
                    .contentShape(Rectangle())
                    .onTapGesture { state.isContentExpanded = true }

                Text("tap to expand full plan")
                    .font(.system(size: 9))
                    .foregroundStyle(OverlayStyle.textHint)
            }
        } else {
            Text("Plan file not found")
                .font(.system(size: codeFont))
                .foregroundStyle(OverlayStyle.textMuted)
        }
    }

    // MARK: Question Content

    private var questionContentView: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 16 : 10) {
            ForEach(Array(questions.enumerated()), id: \.offset) { qIdx, question in
                questionView(question, questionIndex: qIdx)
            }
        }
    }

    @ViewBuilder
    private func questionView(_ question: ParsedQuestion, questionIndex: Int) -> some View {
        let isActive = questionIndex == state.currentQuestionIndex
        let showBadge = (showShortcuts || (isExpanded && hotkeyManager.isCmdHeld)) && isActive

        VStack(alignment: .leading, spacing: isExpanded ? 8 : 3) {
            if let header = question.header {
                Text(header)
                    .font(Constants.heading(size: isExpanded ? 11 : 10, weight: .bold))
                    .foregroundStyle(OverlayStyle.orange)
                    .padding(.horizontal, isExpanded ? 8 : 5)
                    .padding(.vertical, isExpanded ? 2 : 1)
                    .overlay(Capsule().stroke(OverlayStyle.orangeBorder, lineWidth: 1))
            }

            markdownText(question.question)
                .font(Constants.body(size: bodyFont, weight: .medium))
                .foregroundStyle(OverlayStyle.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
                .onTapGesture {
                    if questions.count > 1 { state.currentQuestionIndex = questionIndex }
                    focusTerminal(pid: permission.event.terminalPid, shellPid: permission.event.shellPid, projectDir: permission.event.cwd, sessionId: permission.event.sessionId, sessions: sessionStore.sessions)
                }

            VStack(alignment: .leading, spacing: isExpanded ? 4 : 2) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { idx, option in
                    optionRow(question: question, option: option, index: idx, questionIndex: questionIndex, showBadge: showBadge)
                }
                otherRow(question: question, questionIndex: questionIndex, showBadge: showBadge)
            }
        }
    }

    @ViewBuilder
    private func optionRow(question: ParsedQuestion, option: ParsedOption, index: Int, questionIndex: Int, showBadge: Bool) -> some View {
        let isMulti = question.multiSelect
        let isSelected: Bool = {
            guard !state.usingCustom.contains(question.question) else { return false }
            if isMulti { return state.multiSelections[question.question]?.contains(option.label) == true }
            return state.selections[question.question] == option.label
        }()

        Button {
            state.currentQuestionIndex = questionIndex
            state.usingCustom.remove(question.question)
            if isMulti {
                var set = state.multiSelections[question.question] ?? []
                if set.contains(option.label) { set.remove(option.label) } else { set.insert(option.label) }
                state.multiSelections[question.question] = set
            } else {
                state.selections[question.question] = option.label
                if questionIndex + 1 < questions.count {
                    state.currentQuestionIndex = questionIndex + 1
                }
            }
        } label: {
            HStack(alignment: .top, spacing: isExpanded ? 8 : 5) {
                Image(systemName: isMulti
                    ? (isSelected ? "checkmark.square.fill" : "square")
                    : (isSelected ? "checkmark.circle.fill" : "circle"))
                    .font(.system(size: isExpanded ? 13 : 11))
                    .foregroundStyle(isSelected ? OverlayStyle.orange : OverlayStyle.radioBorder)
                    .frame(width: isExpanded ? 16 : 13)

                VStack(alignment: .leading, spacing: isExpanded ? 2 : 1) {
                    markdownText(option.label)
                        .font(Constants.body(size: optionFont, weight: .medium))
                        .foregroundStyle(OverlayStyle.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let desc = option.description, !desc.isEmpty {
                        markdownText(desc)
                            .font(Constants.body(size: isExpanded ? 11 : 9))
                            .foregroundStyle(OverlayStyle.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)

                if showBadge {
                    ShortcutBadge(index: index, isSelected: hotkeyManager.selectedButtonIndex == index)
                }
            }
            .padding(.vertical, isExpanded ? 6 : 2)
            .padding(.horizontal, isExpanded ? 10 : 5)
            .background(
                (hotkeyManager.selectedButtonIndex == index && showBadge)
                    ? OverlayStyle.orange.opacity(0.12)
                    : (isSelected ? OverlayStyle.selectedBg : Color.clear)
            )
            .clipShape(RoundedRectangle(cornerRadius: isExpanded ? 8 : 7))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func otherRow(question: ParsedQuestion, questionIndex: Int, showBadge: Bool) -> some View {
        let isCustom = state.usingCustom.contains(question.question)
        let otherIndex = question.options.count

        VStack(alignment: .leading, spacing: isExpanded ? 4 : 2) {
            Button {
                state.currentQuestionIndex = questionIndex
                if mode == .compact { store.onRequestTextInputFocus?() }
                state.usingCustom.insert(question.question)
                state.selections.removeValue(forKey: question.question)
                otherFieldFocused = question.question
            } label: {
                HStack(spacing: isExpanded ? 8 : 5) {
                    Image(systemName: isCustom ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: isExpanded ? 13 : 11))
                        .foregroundStyle(isCustom ? OverlayStyle.orange : OverlayStyle.radioBorder)
                        .frame(width: isExpanded ? 16 : 13)

                    Text("Other")
                        .font(Constants.body(size: optionFont, weight: .medium))
                        .foregroundStyle(OverlayStyle.textMuted)

                    Spacer(minLength: 0)

                    if showBadge {
                        ShortcutBadge(index: otherIndex, isSelected: hotkeyManager.selectedButtonIndex == otherIndex)
                    }
                }
                .padding(.vertical, isExpanded ? 6 : 2)
                .padding(.horizontal, isExpanded ? 10 : 5)
                .background(
                    (hotkeyManager.selectedButtonIndex == otherIndex && showBadge)
                        ? OverlayStyle.orange.opacity(0.12)
                        : (isCustom ? OverlayStyle.selectedBg : Color.clear)
                )
                .clipShape(RoundedRectangle(cornerRadius: isExpanded ? 8 : 7))
            }
            .buttonStyle(.plain)

            if isCustom {
                TextField("Type your answer...", text: Binding(
                    get: { state.customInputs[question.question] ?? "" },
                    set: { state.customInputs[question.question] = $0 }
                ))
                .focused($otherFieldFocused, equals: question.question)
                .textFieldStyle(.plain)
                .font(.system(size: optionFont))
                .foregroundStyle(OverlayStyle.textPrimary)
                .padding(isExpanded ? 8 : 3)
                .background(OverlayStyle.inputBg)
                .clipShape(RoundedRectangle(cornerRadius: isExpanded ? 8 : 7))
                .padding(.leading, isExpanded ? 28 : 22)
            }
        }
    }

    // MARK: Standard Content

    @ViewBuilder
    private var standardContentView: some View {
        if isExpanded {
            Text(permission.fullToolInputText)
                .font(.system(size: codeFont, design: .monospaced))
                .foregroundStyle(OverlayStyle.textPrimary.opacity(0.85))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if state.isContentExpanded {
            ScrollView(.vertical, showsIndicators: true) {
                Text(permission.fullToolInputText)
                    .font(.system(size: codeFont, design: .monospaced))
                    .foregroundStyle(OverlayStyle.textPrimary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            .padding(5)
            .background(OverlayStyle.codeBg)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(OverlayStyle.codeBorder, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture { state.isContentExpanded = false }

            Text("tap to collapse")
                .font(.system(size: 9))
                .foregroundStyle(OverlayStyle.textHint)
        } else {
            Text(permission.toolInputPreview)
                .font(.system(size: codeFont, design: .monospaced))
                .foregroundStyle(OverlayStyle.textPrimary.opacity(0.75))
                .lineLimit(2)
                .padding(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(OverlayStyle.codeBg)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(OverlayStyle.codeBorder, lineWidth: 1))
                .contentShape(Rectangle())
                .onTapGesture { state.isContentExpanded = true }
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionsSection: some View {
        if isPlan {
            planActionsView
        } else if isQuestion {
            questionActionsView
        } else {
            standardActionsView
        }
    }

    // MARK: Plan Actions

    private let planOptions = [
        "Yes, clear context and auto-accept edits",
        "Yes, auto-accept edits",
        "Yes, manually approve edits",
        "Tell Claude what to change",
    ]

    private var planActionsView: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 12 : 2) {
            if isExpanded {
                // Horizontal options in expanded mode - equal height via Grid
                Grid(horizontalSpacing: 6) {
                    GridRow {
                        ForEach(Array(planOptions.enumerated()), id: \.offset) { idx, label in
                            planOptionButton(idx: idx, label: label)
                        }
                    }
                }
            } else {
                // Vertical options in compact mode
                ForEach(Array(planOptions.enumerated()), id: \.offset) { idx, label in
                    planOptionButton(idx: idx, label: label)
                }
            }

            // Feedback input
            if state.selectedOption == 3 {
                if isExpanded {
                    TextEditor(text: Binding(
                        get: { state.feedbackText },
                        set: { state.feedbackText = $0 }
                    ))
                    .focused($feedbackFocused)
                    .font(.system(size: 13))
                    .foregroundStyle(OverlayStyle.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 60, maxHeight: 120)
                    .background(OverlayStyle.textPrimary.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(OverlayStyle.orange.opacity(0.2), lineWidth: 1))
                    .overlay(alignment: .topLeading) {
                        if state.feedbackText.isEmpty {
                            Text("Tell Claude what to change...")
                                .font(.system(size: 13))
                                .foregroundStyle(OverlayStyle.textPrimary.opacity(0.3))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .allowsHitTesting(false)
                        }
                    }
                } else {
                    TextField("Type your feedback...", text: Binding(
                        get: { state.feedbackText },
                        set: { state.feedbackText = $0 }
                    ))
                    .focused($feedbackFocused)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(OverlayStyle.textPrimary)
                    .padding(3)
                    .background(OverlayStyle.inputBg)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .padding(.leading, 22)
                }
            }

            // Approve / Deny
            approveAndDenyButtons(
                approveLabel: "Approve",
                denyLabel: "Deny",
                approveDisabled: state.selectedOption == 3 && state.feedbackText.isEmpty,
                onApprove: {
                    if state.selectedOption == 3 && !state.feedbackText.isEmpty {
                        onFeedback?(state.feedbackText)
                    } else if state.selectedOption <= 1 {
                        let autoAccept = [PermissionSuggestion(type: "setMode", destination: "session", behavior: nil, rules: nil, mode: "acceptEdits")]
                        onAllowWithPermissions?(autoAccept)
                    } else {
                        onDecision(.allow)
                    }
                },
                onDeny: { onDecision(.deny) }
            )
        }
    }

    private func planOptionButton(idx: Int, label: String) -> some View {
        let showBadge = showShortcuts || (isExpanded && hotkeyManager.isCmdHeld)

        return Button {
            state.selectedOption = idx
            if idx == 3 {
                if mode == .compact { store.onRequestTextInputFocus?() }
                feedbackFocused = true
            }
        } label: {
            HStack(alignment: .top, spacing: isExpanded ? 6 : 5) {
                Image(systemName: state.selectedOption == idx ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: isExpanded ? 12 : 11))
                    .foregroundStyle(state.selectedOption == idx ? OverlayStyle.orange : OverlayStyle.radioBorder)
                    .frame(width: isExpanded ? nil : 13)
                    .padding(.top, isExpanded ? 2 : 0)

                Text(label)
                    .font(Constants.body(size: optionFont, weight: .medium))
                    .foregroundStyle(OverlayStyle.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                if showBadge {
                    ShortcutBadge(index: idx, isSelected: hotkeyManager.selectedButtonIndex == idx)
                        .padding(.top, isExpanded ? 2 : 0)
                }
            }
            .padding(.vertical, isExpanded ? 10 : 2)
            .padding(.horizontal, isExpanded ? 12 : 5)
            .frame(maxWidth: isExpanded ? .infinity : nil, alignment: .leading)
            .background(
                (hotkeyManager.selectedButtonIndex == idx && showBadge)
                    ? OverlayStyle.orange.opacity(0.12)
                    : (state.selectedOption == idx ? OverlayStyle.selectedBg : (isExpanded ? OverlayStyle.textPrimary.opacity(0.02) : Color.clear))
            )
            .clipShape(RoundedRectangle(cornerRadius: isExpanded ? 8 : 7))
        }
        .buttonStyle(.plain)
    }

    // MARK: Question Actions

    private var questionActionsView: some View {
        approveAndDenyButtons(
            approveLabel: "Submit",
            denyLabel: "Skip",
            approveDisabled: !state.allAnswered(for: questions),
            onApprove: {
                let answers = state.buildAnswers(for: questions)
                onAnswers?(answers)
            },
            onDeny: { onDecision(.deny) }
        )
    }

    // MARK: Standard Actions

    private var standardActionsView: some View {
        VStack(spacing: isExpanded ? 10 : 3) {
            approveAndDenyButtons(
                approveLabel: "Allow",
                denyLabel: "Deny",
                approveDisabled: false,
                onApprove: { onDecision(.allow) },
                onDeny: { onDecision(.deny) }
            )

            // Always-allow suggestions
            ForEach(Array(permission.permissionSuggestions.enumerated()), id: \.element.id) { sugIndex, suggestion in
                let showBadge = showShortcuts || (isExpanded && hotkeyManager.isCmdHeld)
                Button {
                    onAllowWithPermissions?([suggestion])
                } label: {
                    HStack(spacing: 4) {
                        Spacer(minLength: 0)
                        Text(suggestion.displayLabel)
                            .font(Constants.body(size: isExpanded ? 12 : 10, weight: .medium))
                            .foregroundStyle(OverlayStyle.denyText)
                        if showBadge {
                            ShortcutBadge(index: sugIndex, isSelected: hotkeyManager.selectedButtonIndex == sugIndex)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, isExpanded ? 6 : 3)
                    .background(
                        (hotkeyManager.selectedButtonIndex == sugIndex && showBadge)
                            ? OverlayStyle.orange.opacity(0.08)
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: isExpanded ? 8 : 7))
                    .overlay(RoundedRectangle(cornerRadius: isExpanded ? 8 : 7).stroke(
                        (hotkeyManager.selectedButtonIndex == sugIndex && showBadge)
                            ? OverlayStyle.orange
                            : OverlayStyle.denyBorder,
                        lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Shared Approve/Deny Buttons

    @ViewBuilder
    private func approveAndDenyButtons(
        approveLabel: String,
        denyLabel: String,
        approveDisabled: Bool,
        onApprove: @escaping () -> Void,
        onDeny: @escaping () -> Void
    ) -> some View {
        if isExpanded {
            HStack(spacing: 10) {
                Text("⌘P close  ·  ⌘⎋ \(denyLabel.lowercased())  ·  ⌘↵ \(approveLabel.lowercased())")
                    .font(.system(size: hintFont, weight: .medium, design: .rounded))
                    .foregroundStyle(OverlayStyle.textPrimary.opacity(0.35))

                Spacer()

                Button(action: onDeny) {
                    HStack(spacing: 5) {
                        Text(denyLabel)
                            .font(Constants.heading(size: buttonFont, weight: .semibold))
                        if hotkeyManager.isCmdHeld { ActionBadge(label: "⌘⎋") }
                    }
                    .foregroundStyle(OverlayStyle.denyText)
                    .padding(.vertical, buttonPaddingV)
                    .padding(.horizontal, buttonPaddingH)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(OverlayStyle.denyBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: .command)

                Button(action: onApprove) {
                    HStack(spacing: 5) {
                        Text(approveLabel)
                            .font(Constants.heading(size: buttonFont, weight: .semibold))
                        if hotkeyManager.isCmdHeld { ActionBadge(label: "⌘↵") }
                    }
                    .foregroundStyle(.white)
                    .padding(.vertical, buttonPaddingV)
                    .padding(.horizontal, buttonPaddingH)
                    .background(approveDisabled ? Color.gray.opacity(0.3) : OverlayStyle.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(approveDisabled)
            }
            .animation(.easeInOut(duration: 0.15), value: hotkeyManager.isCmdHeld)
        } else {
            HStack(spacing: 5) {
                Button(action: onApprove) {
                    HStack(spacing: 4) {
                        Spacer(minLength: 0)
                        Text(approveLabel)
                            .font(Constants.heading(size: buttonFont, weight: .semibold))
                            .foregroundStyle(.white)
                        if showShortcuts { ActionBadge(label: "⌘↩") }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, buttonPaddingV)
                    .background(approveDisabled ? Color.gray.opacity(0.3) : OverlayStyle.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(approveDisabled)

                Button(action: onDeny) {
                    HStack(spacing: 4) {
                        Spacer(minLength: 0)
                        Text(denyLabel)
                            .font(Constants.heading(size: buttonFont, weight: .semibold))
                            .foregroundStyle(OverlayStyle.denyText)
                        if showShortcuts { ActionBadge(label: "⌘⎋") }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, buttonPaddingV)
                    .background(Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(OverlayStyle.denyBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Shortcut Handlers (compact mode only, via CGEvent tap)

    private func handleShortcutSelection(_ idx: Int) {
        if isPlan {
            if idx < planOptions.count {
                state.selectedOption = idx
                if idx == 3 {
                    store.onRequestTextInputFocus?()
                    feedbackFocused = true
                }
            }
        } else if isQuestion {
            let qIdx = state.currentQuestionIndex
            guard qIdx < questions.count else { return }
            let q = questions[qIdx]
            if idx < q.options.count {
                state.usingCustom.remove(q.question)
                if q.multiSelect {
                    var set = state.multiSelections[q.question] ?? []
                    let label = q.options[idx].label
                    if set.contains(label) { set.remove(label) } else { set.insert(label) }
                    state.multiSelections[q.question] = set
                } else {
                    state.selections[q.question] = q.options[idx].label
                    if qIdx + 1 < questions.count { state.currentQuestionIndex = qIdx + 1 }
                }
            } else if idx == q.options.count {
                store.onRequestTextInputFocus?()
                state.usingCustom.insert(q.question)
                state.selections.removeValue(forKey: q.question)
                otherFieldFocused = q.question
            }
        }
        // Standard permissions: handled by selectedButtonIndex in suggestion buttons
    }

    private func handleShortcutConfirm() {
        if isPlan {
            if state.selectedOption == 3 && !state.feedbackText.isEmpty {
                onFeedback?(state.feedbackText)
            } else if state.selectedOption <= 1 {
                let autoAccept = [PermissionSuggestion(type: "setMode", destination: "session", behavior: nil, rules: nil, mode: "acceptEdits")]
                onAllowWithPermissions?(autoAccept)
            } else {
                onDecision(.allow)
            }
        } else if isQuestion {
            guard state.allAnswered(for: questions) else { return }
            let answers = state.buildAnswers(for: questions)
            onAnswers?(answers)
        } else {
            // Standard: check if a suggestion is selected
            let sug = permission.permissionSuggestions
            if let idx = hotkeyManager.selectedButtonIndex, idx < sug.count {
                onAllowWithPermissions?([sug[idx]])
            } else {
                onDecision(.allow)
            }
        }
    }

    // MARK: - Helpers

    private var titleIcon: String {
        if isPlan { return "doc.text.fill" }
        if isQuestion { return "questionmark.circle.fill" }
        return "shield.checkered"
    }

    private var titleText: String {
        if isPlan { return "Plan Ready" }
        if isQuestion { return "Question" }
        return permission.toolName
    }

    private var projectName: String? {
        guard let sessionId = permission.event.sessionId,
              let session = sessionStore.sessions.first(where: { $0.id == sessionId }) else { return nil }
        return session.projectName
    }
}

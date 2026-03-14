import AppKit
import Foundation

@Observable
final class AppStore {
    let localServer = LocalServer()
    let codexSessionMonitor = CodexSessionMonitor()
    let eventStore = EventStore()
    let sessionStore = SessionStore()
    let notificationStore = NotificationStore()
    let notificationService = NotificationService.shared
    let pendingPermissionStore = PendingPermissionStore()
    let mascotStore = MascotStore()
    let hotkeyManager = GlobalHotkeyManager()
    let sessionSwitcherStore = SessionSwitcherStore()
    let sessionFinishedStore = SessionFinishedStore()

    private(set) var eventProcessor: EventProcessor!
    private(set) var isReady = false
    private(set) var isRunning = false
    private var lastReconcileDate: Date = .distantPast

    /// Called when a Claude Code event is received — wire to OverlayManager.handleEvent
    var onEventForOverlay: ((ClaudeEvent) -> Void)?
    /// Called when a custom input is received via POST /input
    var onInputForOverlay: ((String, ConditionValue) -> Void)?
    /// Called when session phases change outside of events (e.g. interrupt detection via transcript)
    var onRefreshOverlay: (() -> Void)?
    /// Called when the session-finished toast appears/dismisses — trigger panel reposition
    var onToastChanged: (() -> Void)?

    /// Session switcher overlay callbacks — wire to OverlayManager
    var onSessionSwitcherShow: (() -> Void)?
    var onSessionSwitcherUpdate: (() -> Void)?
    var onSessionSwitcherDismiss: (() -> Void)?

    /// Set by URL handler to navigate to a mascot after install
    var navigateToMascotId: UUID?

    var hasUnreadNotifications: Bool { notificationStore.unreadCount > 0 }

    var hasCompletedOnboarding: Bool = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }

    init() {
        self.eventProcessor = EventProcessor(
            eventStore: eventStore,
            sessionStore: sessionStore,
            notificationStore: notificationStore,
            notificationService: notificationService
        )

        // Wire local server → event processor + overlay state machine
        localServer.onEventReceived = { [weak self] event in
            guard let self else { return }
            Task { @MainActor in
                await self.handleIncomingEvent(event)
            }
        }

        // Wire Codex session logs → shared event pipeline
        codexSessionMonitor.onEventReceived = { [weak self] event in
            guard let self else { return }
            Task { @MainActor in
                await self.handleIncomingEvent(event)
            }
        }

        // Wire local server → custom input endpoint
        localServer.onInputReceived = { [weak self] name, value in
            guard let self else { return }
            Task { @MainActor in
                self.onInputForOverlay?(name, value)
            }
        }

        // Wire local server → permission requests (hold connection for user decision)
        localServer.onPermissionRequest = { [weak self] event, connection in
            guard let self else { return }
            Task { @MainActor in
                self.pendingPermissionStore.add(event: event, connection: connection)
            }
        }

        // Wire interrupt detection → overlay refresh + session count sync + switcher refresh
        sessionStore.onPhasesChanged = { [weak self] in
            guard let self else { return }
            self.onRefreshOverlay?()
            let activeCount = self.sessionStore.activeSessions.count
            self.hotkeyManager.activeSessionCount = activeCount

            // Auto-dismiss or refresh session switcher when sessions change
            if self.sessionSwitcherStore.isActive {
                if activeCount < 2 {
                    self.sessionSwitcherStore.close()
                    self.syncActiveCard()
                    self.onSessionSwitcherDismiss?()
                } else {
                    self.sessionSwitcherStore.refresh(sessions: self.sessionStore.activeSessions)
                    self.onSessionSwitcherUpdate?()
                }
            }
        }

        // Wire pending permission count → sync active card
        pendingPermissionStore.onPendingCountChange = { [weak self] in
            self?.syncActiveCard()
        }

        // Wire session finished toast dismiss → sync active card + panel reposition
        sessionFinishedStore.onDismiss = { [weak self] in
            self?.syncActiveCard()
            self?.onToastChanged?()
        }

        // Set initial count
        hotkeyManager.activeSessionCount = sessionStore.activeSessions.count

        // Wire session switcher tap-to-confirm (clicked a row)
        sessionSwitcherStore.onTapConfirm = { [weak self] session in
            guard let self else { return }
            self.sessionSwitcherStore.close()
            self.syncActiveCard()
            IDETerminalFocus.focusSession(session)
            self.onSessionSwitcherDismiss?()
        }

        // Wire hotkey manager — session switcher open (double-tap Cmd)
        hotkeyManager.onSessionSwitcherOpen = { [weak self] in
            guard let self else { return }
            let active = self.sessionStore.activeSessions
            self.sessionSwitcherStore.open(sessions: active)
            self.syncActiveCard()
            self.onSessionSwitcherShow?()
        }

        hotkeyManager.onSessionSwitcherNext = { [weak self] in
            self?.sessionSwitcherStore.selectNext()
            self?.onSessionSwitcherUpdate?()
        }

        hotkeyManager.onSessionSwitcherPrev = { [weak self] in
            self?.sessionSwitcherStore.selectPrevious()
            self?.onSessionSwitcherUpdate?()
        }

        // Wire hotkey manager — ⌘N selects Nth item within topmost card
        hotkeyManager.onSelect = { [weak self] index in
            guard let self else { return }
            switch self.hotkeyManager.activeCard {
            case .sessionSwitcher:
                self.sessionSwitcherStore.selectIndex(index)
                // Immediately confirm — Cmd+N is a direct jump
                if let session = self.sessionSwitcherStore.confirm() {
                    IDETerminalFocus.focusSession(session)
                }
                self.syncActiveCard()
                self.onSessionSwitcherDismiss?()
            case .permission:
                guard !self.pendingPermissionStore.pending.isEmpty else { return }
                if self.hotkeyManager.selectedButtonIndex == index {
                    self.hotkeyManager.selectedButtonIndex = nil
                } else {
                    self.hotkeyManager.selectedButtonIndex = index
                }
            case .toast, .none:
                break
            }
        }

        // Wire hotkey manager — ⌘Enter confirms the topmost card
        hotkeyManager.onConfirm = { [weak self] in
            guard let self else { return }
            switch self.hotkeyManager.activeCard {
            case .sessionSwitcher:
                if let session = self.sessionSwitcherStore.confirm() {
                    IDETerminalFocus.focusSession(session)
                }
                self.syncActiveCard()
                self.onSessionSwitcherDismiss?()
            case .permission:
                self.hotkeyManager.confirmTrigger += 1
            case .toast:
                self.sessionFinishedStore.dismiss()
            case .none:
                break
            }
        }

        // Wire hotkey manager — Esc/⌘Esc dismisses the topmost card
        hotkeyManager.onDismiss = { [weak self] in
            guard let self else { return }
            switch self.hotkeyManager.activeCard {
            case .sessionSwitcher:
                self.sessionSwitcherStore.close()
                self.syncActiveCard()
                self.onSessionSwitcherDismiss?()
            case .permission:
                let reversed = Array(self.pendingPermissionStore.pending.reversed())
                guard let topPerm = reversed.first(where: { !self.pendingPermissionStore.collapsed.contains($0.id) }) else { return }
                self.pendingPermissionStore.resolve(id: topPerm.id, decision: .deny)
            case .toast:
                self.sessionFinishedStore.dismiss()
            case .none:
                break
            }
        }

        // Wire hotkey manager — ⌘L toggles collapse: collapse topmost, or expand if all collapsed
        hotkeyManager.onCollapsePermission = { [weak self] in
            guard let self else { return }
            let reversed = Array(self.pendingPermissionStore.pending.reversed())
            if let topNonCollapsed = reversed.first(where: { !self.pendingPermissionStore.collapsed.contains($0.id) }) {
                self.pendingPermissionStore.collapse(id: topNonCollapsed.id)
            } else if let topCollapsed = reversed.first {
                self.pendingPermissionStore.expand(id: topCollapsed.id)
            }
        }

        // Wire hotkey manager — toggle focus via configurable shortcut (⌘M)
        // Focuses the terminal of the topmost card's session, or toggles dashboard.
        hotkeyManager.onToggleFocus = { [weak self] in
            guard let self else { return }
            let reversed = Array(self.pendingPermissionStore.pending.reversed())
            if let topPerm = reversed.first {
                let sessionDir = self.sessionStore.sessions.first(where: { $0.id == topPerm.event.sessionId })?.projectDir
                IDETerminalFocus.focus(
                    terminalPid: topPerm.event.terminalPid,
                    shellPid: topPerm.event.shellPid,
                    projectDir: sessionDir ?? topPerm.event.cwd
                )
            } else if let toast = self.sessionFinishedStore.current,
                      let session = self.sessionStore.sessions.first(where: { $0.id == toast.sessionId }) {
                IDETerminalFocus.focusSession(session)
                self.sessionFinishedStore.dismiss()
            } else if let session = self.sessionStore.sessions.last(where: { $0.terminalPid != nil }) {
                IDETerminalFocus.focusSession(session)
            } else {
                self.hotkeyManager.toggleFocus()
            }
        }

        // Update permission notification with resolution outcome
        pendingPermissionStore.onResolved = { [weak self] event, outcome in
            guard let self else { return }
            for notification in self.notificationStore.notifications where
                notification.resolutionOutcome == .pending &&
                notification.category == .permissionRequest &&
                notification.sessionId == event.sessionId {
                self.notificationStore.updateResolution(notification.id, outcome: outcome)
                break
            }
        }
    }

    @MainActor
    private func handleIncomingEvent(_ event: ClaudeEvent) async {
        await eventProcessor.process(event)

        // If a subsequent event arrives for a session with pending permissions,
        // the user may have resolved a permission from the terminal — dismiss it.
        // For postToolUse/postToolUseFailure: only dismiss the SPECIFIC tool use
        // that completed (by toolUseId), not all permissions for the agent.
        // For stop/userPromptSubmit: session is ending, dismiss all for that agent.
        if let eventType = event.eventType,
           let sid = event.sessionId {
            // Cache PreToolUse toolUseId — fires immediately before PermissionRequest
            // for the same tool call, and carries the tool_use_id that PermissionRequest lacks.
            if eventType == .preToolUse,
               let toolUseId = event.toolUseId,
               let toolName = event.toolName {
                pendingPermissionStore.cachePreToolUse(
                    sessionId: sid, agentId: event.agentId,
                    toolName: toolName, toolUseId: toolUseId
                )
            }

            if [.stop, .userPromptSubmit].contains(eventType),
               pendingPermissionStore.pending.contains(where: {
                   $0.event.sessionId == sid && $0.event.agentId == event.agentId
               }) {
                pendingPermissionStore.dismissForAgent(sessionId: sid, agentId: event.agentId)
            } else if [.postToolUse, .postToolUseFailure].contains(eventType),
                      let toolUseId = event.toolUseId {
                // Only dismiss the specific permission whose tool was just executed
                // (i.e. user answered from terminal, not from the overlay).
                pendingPermissionStore.dismissByToolUseId(sessionId: sid, toolUseId: toolUseId)
            }
        }

        // Show "task completed" toast when assistant finishes (skip interrupts)
        if event.eventType == .stop,
           event.reason != "interrupted",
           !pendingPermissionStore.pending.contains(where: { $0.event.sessionId == event.sessionId }) {
            sessionFinishedStore.show(
                sessionId: event.sessionId ?? "",
                projectName: event.projectName ?? "Project"
            )
            syncActiveCard()
            // Trigger overlay panel reposition after SwiftUI renders the toast
            onToastChanged?()
        }

        // Dismiss toast when user starts typing (already back in the loop)
        if event.eventType == .userPromptSubmit {
            sessionFinishedStore.dismiss()
        }

        onEventForOverlay?(event)
    }

    /// Recompute which overlay card has priority and sync to the hotkey shared state.
    /// Call whenever any card's visibility changes.
    func syncActiveCard() {
        if sessionSwitcherStore.isActive {
            hotkeyManager.activeCard = .sessionSwitcher
        } else if !pendingPermissionStore.pending.isEmpty {
            hotkeyManager.activeCard = .permission
        } else if sessionFinishedStore.current != nil {
            hotkeyManager.activeCard = .toast
        } else {
            hotkeyManager.activeCard = .none
        }
    }

    /// Call once from .task {} on the menu bar view
    func start() async {
        guard !isRunning else { return }
        isRunning = true
        do {
            try HookInstaller.install()
        } catch {
            print("[masko-desktop] Failed to install hooks: \(error)")
        }

        // Evict cached videos older than 30 days
        VideoCache.shared.evictStaleFiles()

        // Only request permissions if onboarding is done.
        // During onboarding, each permission is requested by its dedicated step.
        if hasCompletedOnboarding {
            hotkeyManager.start()
            await notificationService.requestPermission()

            // Auto-upgrade IDE extension if a newer version is bundled
            if UserDefaults.standard.bool(forKey: "ideExtensionEnabled") {
                ExtensionInstaller.upgradeIfNeeded()
            }
        }

        do {
            try localServer.start()
        } catch {
            print("[masko-desktop] Failed to start local server: \(error)")
        }
        codexSessionMonitor.start(bootstrapRecentFiles: sessionStore.activeSessions.isEmpty)

        // Reconcile sessions when app comes to foreground (crash recovery).
        // Throttled to at most once per 30 seconds — this notification fires on every
        // app switch (Cmd+Tab), not just when Masko activates.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = Date()
                if now.timeIntervalSince(self.lastReconcileDate) >= 30 {
                    self.lastReconcileDate = now
                    self.sessionStore.reconcileIfNeeded()
                }
                // Retry hotkey manager if not yet active (user may have just granted Accessibility)
                if !self.hotkeyManager.isActive {
                    self.hotkeyManager.start()
                }
            }
        }

        // Clean up on app termination to avoid zombie NWListener processes
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stop()
            }
        }

        isReady = true
    }

    /// Tear down server and timers to prevent zombie processes
    func stop() {
        localServer.stop()
        codexSessionMonitor.stop()
        sessionStore.stopTimers()
        pendingPermissionStore.stopTimers()
        hotkeyManager.stop()
    }
}

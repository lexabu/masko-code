import Foundation

@Observable
final class SessionSwitcherStore {
    private(set) var isActive = false
    private(set) var selectedIndex: Int = 0
    private(set) var sessions: [AgentSession] = []
    private var autoDismissTimer: Timer?

    /// Called when user taps a row — AppStore wires this to focus terminal + dismiss.
    var onTapConfirm: ((AgentSession) -> Void)?
    /// Called when auto-dismiss fires — AppStore wires this to update activeCard.
    var onAutoDismiss: (() -> Void)?

    func open(sessions: [AgentSession]) {
        // Running sessions first, then by most recently active.
        self.sessions = sessions.sorted {
            if $0.phase == .running && $1.phase != .running { return true }
            if $0.phase != .running && $1.phase == .running { return false }
            return ($0.lastEventAt ?? $0.startedAt) > ($1.lastEventAt ?? $1.startedAt)
        }
        self.selectedIndex = 0 // Start on the most recent session
        self.isActive = true
        resetAutoDismissTimer()
    }

    func selectNext() {
        guard isActive, !sessions.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % sessions.count
        resetAutoDismissTimer()
    }

    func selectPrevious() {
        guard isActive, !sessions.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + sessions.count) % sessions.count
        resetAutoDismissTimer()
    }

    func selectIndex(_ index: Int) {
        guard isActive, index >= 0, index < sessions.count else { return }
        selectedIndex = index
    }

    var selectedSession: AgentSession? {
        guard isActive, selectedIndex >= 0, selectedIndex < sessions.count else { return nil }
        return sessions[selectedIndex]
    }

    func confirm() -> AgentSession? {
        guard isActive else { return nil }
        let session = selectedSession
        close()
        return session
    }

    /// Select an index and immediately confirm (for tap/click interactions).
    func tapConfirm(index: Int) {
        guard isActive, index >= 0, index < sessions.count else { return }
        selectedIndex = index
        if let session = confirm() {
            onTapConfirm?(session)
        }
    }

    /// Refresh the session list while keeping the current selection if possible.
    func refresh(sessions: [AgentSession]) {
        guard isActive else { return }
        let previousId = selectedSession?.id
        self.sessions = sessions.sorted {
            if $0.phase == .running && $1.phase != .running { return true }
            if $0.phase != .running && $1.phase == .running { return false }
            return ($0.lastEventAt ?? $0.startedAt) > ($1.lastEventAt ?? $1.startedAt)
        }
        if let previousId, let newIdx = self.sessions.firstIndex(where: { $0.id == previousId }) {
            selectedIndex = newIdx
        } else {
            selectedIndex = min(selectedIndex, max(sessions.count - 1, 0))
        }
    }

    func close() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
        isActive = false
        sessions = []
        selectedIndex = 0
    }

    /// Auto-dismiss after 5 seconds of no interaction to prevent stuck keyboard capture.
    private func resetAutoDismissTimer() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.isActive else { return }
                self.close()
                self.onAutoDismiss?()
            }
        }
    }
}

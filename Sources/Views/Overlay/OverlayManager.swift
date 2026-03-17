import AppKit
import SwiftUI

/// NSHostingController subclass that supports transparent background
final class TransparentHostingController<Content: View>: NSHostingController<Content> {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.layer?.isOpaque = false
        view.layer?.masksToBounds = false
    }
}

/// Manages the floating mascot overlay panel lifecycle.
/// Uses two panels: a fixed-size mascot panel and a child HUD panel above it.
@MainActor
@Observable
final class OverlayManager {
    private(set) var isOverlayActive = false
    private(set) var currentURL: URL?
    private(set) var currentConfig: MaskoAnimationConfig?
    private(set) var currentStateMachine: OverlayStateMachine?
    private var panel: OverlayPanel?           // Mascot video — fixed size
    private var statsPanel: OverlayPanel?      // Stats/debug — fixed directly above mascot
    private var permissionPanel: OverlayPanel? // Permission prompts — smart-positioned
    private var permissionHUDConfig = PermissionHUDConfig()
    private var workspaceObservers: [NSObjectProtocol] = []

    // Overlay enabled/disabled (notification-only mode)
    // Stored property so @Observable can track it for SwiftUI reactivity
    private(set) var isOverlayEnabled: Bool = UserDefaults.standard.bool(forKey: "overlay_enabled")

    // Snooze state
    private(set) var isSnoozed = false
    private(set) var snoozeEndDate: Date?
    private var snoozeTimer: Timer?
    private var snoozedConfig: MaskoAnimationConfig?

    // Context menu panel
    private var contextPanel: ContextMenuPanel?

    // Auto-hide when no Claude Code sessions are active
    private(set) var isAutoHideEnabled: Bool = UserDefaults.standard.object(forKey: "auto_hide_no_sessions") != nil
        ? UserDefaults.standard.bool(forKey: "auto_hide_no_sessions")
        : true  // Default on
    private(set) var isAutoHidden = false
    private var autoHideTimer: Timer?
    private(set) var autoHideDelay: TimeInterval = {
        let saved = UserDefaults.standard.double(forKey: "auto_hide_delay")
        return saved >= 0 && UserDefaults.standard.object(forKey: "auto_hide_delay") != nil ? saved : 15
    }()

    // Coalescing flag for HUD repositioning — prevents recursive layout cycles
    private var hudRepositionScheduled = false

    // Stores passed from AppStore for overlay display
    // Non-optional with defaults — avoids @Environment crash when overlay renders before stores are set
    var sessionStore: SessionStore = SessionStore()
    var eventStore: EventStore = EventStore()
    var pendingPermissionStore: PendingPermissionStore = PendingPermissionStore()
    var hotkeyManager: GlobalHotkeyManager = GlobalHotkeyManager()
    var sessionSwitcherStore: SessionSwitcherStore = SessionSwitcherStore()
    var sessionFinishedStore: SessionFinishedStore = SessionFinishedStore()

    var currentSizePixels: Int {
        get {
            let saved = UserDefaults.standard.integer(forKey: "overlay_size")
            return saved > 0 ? saved : OverlaySize.medium.rawValue
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "overlay_size")
            resizePanelToPixels(newValue)
        }
    }

    func showOverlay(url: URL) {
        guard isOverlayEnabled else { return }
        // If same URL already active, just re-assert
        if panel != nil, currentURL == url {
            reassertPanel()
            isOverlayActive = true
            return
        }

        // Close existing
        hideOverlay()

        let px = currentSizePixels
        let size = CGSize(width: px, height: px)
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero

        // Restore position or default to bottom-right
        let savedX = UserDefaults.standard.double(forKey: "overlay_x")
        let savedY = UserDefaults.standard.double(forKey: "overlay_y")
        let origin: CGPoint
        if savedX > 0 || savedY > 0 {
            origin = CGPoint(x: savedX, y: savedY)
        } else {
            origin = CGPoint(
                x: screenFrame.maxX - size.width - 40,
                y: screenFrame.minY + 40
            )
        }

        let rect = NSRect(origin: origin, size: size)
        let newPanel = OverlayPanel(contentRect: rect)

        let view = OverlayMascotView(
            url: url,
            onClose: { [weak self] in self?.hideOverlay() },
            onResize: { [weak self] newSize in self?.currentSizePixels = newSize.rawValue },
            onDragResize: { [weak self] size in self?.resizePanelLive(size) },
            onDragResizeEnd: { [weak self] size in self?.currentSizePixels = size },
            onSnooze: { [weak self] minutes in self?.snooze(minutes: minutes) }
        )

        let controller = TransparentHostingController(rootView: view)
        newPanel.contentView = controller.view
        newPanel.contentViewController = controller

        // Right-click handler
        newPanel.onRightClick = { [weak self] point in self?.showContextMenu(at: point) }

        // Restore saved opacity
        let savedOpacity = UserDefaults.standard.double(forKey: "overlay_opacity")
        newPanel.alphaValue = savedOpacity > 0 ? savedOpacity : 1.0

        // Show without stealing focus
        newPanel.orderFrontRegardless()

        // Move into a system-level Space that doesn't participate in Space swipe animations
        SkyLightOperator.shared.delegateWindow(newPanel)

        print("[masko-desktop] Overlay panel shown at \(rect), level=\(newPanel.level.rawValue)")

        self.panel = newPanel
        self.currentURL = url
        self.isOverlayActive = true

        // Save URL for restore on relaunch
        UserDefaults.standard.set(url.absoluteString, forKey: "overlay_url")

        setupObservers(for: newPanel)
    }

    /// Show overlay using a canvas config with a full state machine.
    /// Creates two panels: mascot (fixed) + HUD (child, above).
    func showOverlayWithConfig(_ config: MaskoAnimationConfig) {
        guard isOverlayEnabled else { return }
        // Cancel any active snooze
        cancelSnooze()

        // Close existing
        hideOverlay()

        self.currentConfig = config

        // Pre-download all videos immediately (fire and forget)
        Task { await VideoCache.shared.preload(config: config) }

        // Save config JSON for restore on relaunch
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: "overlay_config")
        }

        // Create state machine
        let sm = OverlayStateMachine(config: config)
        self.currentStateMachine = sm
        sm.start()

        // --- Mascot panel (fixed size, just the video) ---
        let px = currentSizePixels
        let size = CGSize(width: px, height: px)
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero

        let savedX = UserDefaults.standard.double(forKey: "overlay_x")
        let savedY = UserDefaults.standard.double(forKey: "overlay_y")
        let origin: CGPoint
        if savedX > 0 || savedY > 0 {
            origin = CGPoint(x: savedX, y: savedY)
        } else {
            origin = CGPoint(
                x: screenFrame.maxX - size.width - 40,
                y: screenFrame.minY + 40
            )
        }

        let mascotRect = NSRect(origin: origin, size: size)
        let mascotPanel = OverlayPanel(contentRect: mascotRect)

        let mascotView = OverlayStateMachineView(
            stateMachine: sm,
            onClose: { [weak self] in self?.hideOverlay() },
            onResize: { [weak self] newSize in self?.currentSizePixels = newSize.rawValue },
            onDragResize: { [weak self] size in self?.resizePanelLive(size) },
            onDragResizeEnd: { [weak self] size in self?.currentSizePixels = size },
            onSnooze: { [weak self] minutes in self?.snooze(minutes: minutes) }
        )

        let mascotController = TransparentHostingController(rootView: mascotView)
        mascotPanel.contentView = mascotController.view
        mascotPanel.contentViewController = mascotController

        // Right-click handler
        mascotPanel.onRightClick = { [weak self] point in self?.showContextMenu(at: point) }

        // Restore saved opacity
        let savedOpacity = UserDefaults.standard.double(forKey: "overlay_opacity")
        mascotPanel.alphaValue = savedOpacity > 0 ? savedOpacity : 1.0

        mascotPanel.orderFrontRegardless()
        SkyLightOperator.shared.delegateWindow(mascotPanel)

        // --- Stats panel (fixed directly above mascot) ---
        let statsView = StatsHUDView(stateMachine: sm)
            .environment(sessionStore)
            .environment(pendingPermissionStore)

        let statsWidth: CGFloat = 180
        let statsController = TransparentHostingController(rootView: statsView)
        let statsHeight = max(statsController.view.fittingSize.height, 20)
        let statsRect = NSRect(
            x: mascotRect.midX - statsWidth / 2,
            y: mascotRect.maxY + 4,
            width: statsWidth,
            height: statsHeight
        )
        let newStatsPanel = OverlayPanel(contentRect: statsRect)
        newStatsPanel.isMovableByWindowBackground = false

        // Right-click on stats opens same context menu as mascot
        newStatsPanel.onRightClick = { [weak self] point in self?.showContextMenu(at: point) }

        newStatsPanel.contentView = statsController.view
        newStatsPanel.contentViewController = statsController

        newStatsPanel.orderFrontRegardless()
        SkyLightOperator.shared.delegateWindow(newStatsPanel)
        mascotPanel.addChildWindow(newStatsPanel, ordered: .above)

        // --- Permission panel (smart-positioned, adapts to screen edges) ---
        permissionHUDConfig = PermissionHUDConfig()
        permissionHUDConfig.onContentSizeChange = { [weak self] _ in
            self?.scheduleHUDReposition()
        }
        let permView = PermissionHUDView(config: permissionHUDConfig)
            .environment(pendingPermissionStore)
            .environment(hotkeyManager)
            .environment(sessionSwitcherStore)
            .environment(sessionStore)
            .environment(sessionFinishedStore)

        let permController = TransparentHostingController(rootView: permView)
        permController.sizingOptions = []

        let statsTop = statsRect.maxY
        let permRect = NSRect(
            x: mascotRect.midX - 140,
            y: statsTop + 4,
            width: 280,
            height: 200
        )
        let newPermPanel = OverlayPanel(contentRect: permRect)
        newPermPanel.isMovableByWindowBackground = false
        newPermPanel.contentView = permController.view
        newPermPanel.contentViewController = permController

        // Resize/reposition when permissions change (delay lets SwiftUI render)
        pendingPermissionStore.onPendingChange = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self?.scheduleHUDReposition()
            }
        }

        // Activate app + make permission panel key when a text-input field needs focus
        pendingPermissionStore.onRequestTextInputFocus = { [weak self] in
            guard let permPanel = self?.permissionPanel else { return }
            NSApp.activate(ignoringOtherApps: true)
            permPanel.makeKey()
        }

        newPermPanel.orderFrontRegardless()
        SkyLightOperator.shared.delegateWindow(newPermPanel)
        mascotPanel.addChildWindow(newPermPanel, ordered: .above)

        print("[masko-desktop] State machine overlay: mascot=\(mascotRect), stats+perm panels")

        self.panel = mascotPanel
        self.statsPanel = newStatsPanel
        self.permissionPanel = newPermPanel
        self.isOverlayActive = true

        setupObservers(for: mascotPanel)

        // Also reposition HUD when mascot moves (child windows move together,
        // but we need to keep the HUD anchored to the top)
        let moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: mascotPanel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleHUDReposition() }
        }
        workspaceObservers.append(moveObserver)
    }

    /// Recompute aggregate session state and push inputs to the state machine.
    /// Can be called independently (e.g. after interrupt detection) without needing an event.
    func refreshInputs() {
        let active = sessionStore.activeSessions

        // Auto-hide: fade out when all sessions idle, fade in when any session is working
        let anyWorking = active.contains { $0.phase == .running || $0.phase == .compacting }
        updateAutoHideState(isWorking: anyWorking)

        guard let sm = currentStateMachine else { return }

        let isWorking = active.contains { $0.phase == .running }
        let isIdle = active.allSatisfy { $0.phase == .idle } || active.isEmpty
        // Only alert if a pending permission belongs to a session that's still active
        // (collapsed/ended sessions lose priority to working sessions)
        let activeSessionIds = Set(active.map(\.id))
        let isAlert = pendingPermissionStore.pending.contains { perm in
            guard let sid = perm.event.sessionId else { return false }
            return activeSessionIds.contains(sid)
        }
        let isCompacting = active.contains { $0.isCompacting }
        let sessionCount = active.count

        sm.setInput("claudeCode::isWorking", .bool(isWorking))
        sm.setInput("claudeCode::isIdle", .bool(isIdle))
        sm.setInput("claudeCode::isAlert", .bool(isAlert))
        sm.setInput("claudeCode::isCompacting", .bool(isCompacting))
        sm.setInput("claudeCode::sessionCount", .number(Double(sessionCount)))
    }

    // MARK: - Auto-Hide (no active sessions)

    func setAutoHideEnabled(_ enabled: Bool) {
        isAutoHideEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "auto_hide_no_sessions")
        if enabled {
            // Start tracking immediately
            let anyWorking = sessionStore.activeSessions.contains { $0.phase == .running || $0.phase == .compacting }
            updateAutoHideState(isWorking: anyWorking)
        } else {
            // Cancel any pending hide and restore if hidden
            autoHideTimer?.invalidate()
            autoHideTimer = nil
            if isAutoHidden {
                fadeInFromAutoHide()
            }
        }
    }

    func setAutoHideDelay(_ delay: TimeInterval) {
        autoHideDelay = delay
        UserDefaults.standard.set(autoHideDelay, forKey: "auto_hide_delay")
        // Restart timer if one is already running
        if autoHideTimer != nil {
            autoHideTimer?.invalidate()
            autoHideTimer = nil
            let anyWorking = sessionStore.activeSessions.contains { $0.phase == .running || $0.phase == .compacting }
            updateAutoHideState(isWorking: anyWorking)
        }
    }

    private func updateAutoHideState(isWorking: Bool) {
        guard isAutoHideEnabled, isOverlayActive || isAutoHidden else { return }

        if isWorking {
            // A session is working — cancel any pending hide and restore if hidden
            autoHideTimer?.invalidate()
            autoHideTimer = nil
            if isAutoHidden {
                fadeInFromAutoHide()
            }
        } else if !isAutoHidden && autoHideTimer == nil {
            // All sessions idle — start countdown to fade out
            autoHideTimer = Timer.scheduledTimer(withTimeInterval: autoHideDelay, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.fadeOutForAutoHide()
                }
            }
        }
    }

    private func fadeOutForAutoHide() {
        autoHideTimer = nil
        guard isOverlayActive, !isAutoHidden else { return }
        isAutoHidden = true

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.6
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel?.animator().alphaValue = 0
            statsPanel?.animator().alphaValue = 0
            permissionPanel?.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.isAutoHidden else { return }
                self.panel?.orderOut(nil)
                self.statsPanel?.orderOut(nil)
                self.permissionPanel?.orderOut(nil)
                print("[masko-desktop] Auto-hidden (no active sessions)")
            }
        }
    }

    private func fadeInFromAutoHide() {
        guard isAutoHidden else { return }
        isAutoHidden = false

        // Restore panels to screen (invisible first)
        panel?.alphaValue = 0
        statsPanel?.alphaValue = 0
        permissionPanel?.alphaValue = 0
        panel?.orderFrontRegardless()
        statsPanel?.orderFrontRegardless()
        permissionPanel?.orderFrontRegardless()

        let savedOpacity = UserDefaults.standard.double(forKey: "overlay_opacity")
        let targetOpacity = savedOpacity > 0 ? savedOpacity : 1.0

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.4
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.panel?.animator().alphaValue = targetOpacity
            self.statsPanel?.animator().alphaValue = 1.0
            self.permissionPanel?.animator().alphaValue = 1.0
        }

        print("[masko-desktop] Auto-shown (session detected)")
    }

    /// Compute aggregate session state and push inputs to the state machine.
    /// Called after SessionStore.recordEvent() has already updated session phases.
    func handleEvent(_ event: ClaudeEvent) {
        refreshInputs()

        // Fire granular event trigger (auto-resets after transition)
        guard let sm = currentStateMachine else { return }
        let eventInput = "claudeCode::\(event.hookEventName)"
        sm.setInput(eventInput, .bool(true))
    }

    /// Temporarily hide the overlay and restore it after the given duration.
    /// Pass `minutes: 0` for indefinite snooze (until manually woken).
    func snooze(minutes: Int) {
        guard isOverlayActive, let config = currentConfig else { return }
        snoozedConfig = config

        let endDate: Date
        if minutes > 0 {
            endDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        } else {
            endDate = .distantFuture // indefinite
        }
        snoozeEndDate = endDate
        isSnoozed = true

        // Persist snooze state
        UserDefaults.standard.set(endDate.timeIntervalSince1970, forKey: "snooze_end_date")

        // Show toast before hiding
        showSnoozeToast(minutes: minutes)

        // Hide overlay but keep config in UserDefaults for restore
        hideOverlay(clearConfig: false)

        // Schedule auto-restore (only for timed snooze)
        if minutes > 0 {
            snoozeTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.wakeFromSnooze()
                }
            }
        }
    }

    /// Cancel snooze and restore the overlay immediately.
    func wakeFromSnooze() {
        guard isOverlayEnabled else { return }
        snoozeTimer?.invalidate()
        snoozeTimer = nil
        let config = snoozedConfig
        snoozedConfig = nil
        snoozeEndDate = nil
        isSnoozed = false
        UserDefaults.standard.removeObject(forKey: "snooze_end_date")

        if let config {
            showOverlayWithConfig(config)
        }
    }

    func hideOverlay(clearConfig: Bool = true) {
        // Reset auto-hide state
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        isAutoHidden = false

        // Remove all observers
        for observer in workspaceObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        dismissContextMenu()
        dismissSessionSwitcher()
        permissionPanel?.close()
        permissionPanel = nil
        statsPanel?.close()
        statsPanel = nil
        panel?.close()
        panel = nil
        currentURL = nil
        currentConfig = nil
        currentStateMachine = nil
        isOverlayActive = false

        if clearConfig {
            UserDefaults.standard.removeObject(forKey: "overlay_url")
            UserDefaults.standard.removeObject(forKey: "overlay_config")
        }
    }

    /// Disable the mascot overlay (notification-only mode).
    /// Hides mascot panel, recreates stats + permission panels in standalone mode.
    func disableOverlay() {
        isOverlayEnabled = false
        UserDefaults.standard.set(false, forKey: "overlay_enabled")
        cancelSnooze()

        // Save mascot position — overlay_x/y is always the mascot origin
        if let panel {
            let f = panel.frame
            UserDefaults.standard.set(f.origin.x, forKey: "overlay_x")
            UserDefaults.standard.set(f.origin.y, forKey: "overlay_y")
        }

        // Capture exact stats panel frame before closing — use it for standalone placement
        let previousStatsFrame = statsPanel?.frame

        // Clear standalone position so it re-derives from mascot on next disable
        UserDefaults.standard.removeObject(forKey: "standalone_x")
        UserDefaults.standard.removeObject(forKey: "standalone_y")

        // Close everything and rebuild in standalone mode
        for observer in workspaceObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        dismissContextMenu()
        dismissSessionSwitcher()
        permissionPanel?.close()
        permissionPanel = nil
        statsPanel?.close()
        statsPanel = nil
        panel?.close()
        panel = nil
        currentURL = nil
        currentConfig = nil
        currentStateMachine = nil
        isOverlayActive = false

        // Recreate stats + permission panels in standalone mode
        showPermissionPanelStandalone(previousStatsFrame: previousStatsFrame)
    }

    /// Re-enable the mascot overlay.
    func enableOverlay() {
        isOverlayEnabled = true
        UserDefaults.standard.set(true, forKey: "overlay_enabled")
    }

    /// Show just the permission panel + stats in standalone mode (no mascot, no tail, bottom-right).
    /// - Parameter previousStatsFrame: The exact frame of the stats panel before it was closed (for seamless transition).
    func showPermissionPanelStandalone(previousStatsFrame: NSRect? = nil) {
        guard permissionPanel == nil else { return }

        let screen = NSScreen.main?.visibleFrame ?? .zero

        // --- Stats panel (standalone, draggable anchor) ---
        // Wrap in frame(maxWidth: .infinity) to center the capsule pill — matches StatsHUDView layout
        let statsView = StatsOverlayView()
            .frame(maxWidth: .infinity)
            .environment(sessionStore)
            .environment(pendingPermissionStore)

        let statsController = TransparentHostingController(rootView: statsView)
        let fittingSize = statsController.view.fittingSize
        let minWidth: CGFloat = 180
        let finalHeight = max(fittingSize.height, 20)
        let finalWidth = max(fittingSize.width, minWidth)

        // Position priority: previous stats frame > saved standalone pos > derive from mascot > default
        let statsRect: NSRect
        if let prev = previousStatsFrame {
            // Place at exact same position as the mascot-mode stats panel
            let centerX = prev.midX
            statsRect = NSRect(
                x: centerX - finalWidth / 2,
                y: prev.origin.y,
                width: finalWidth,
                height: prev.height  // Exact same height to avoid pixel shift
            )
        } else {
            let standaloneX = UserDefaults.standard.double(forKey: "standalone_x")
            let standaloneY = UserDefaults.standard.double(forKey: "standalone_y")
            let savedX = UserDefaults.standard.double(forKey: "overlay_x")
            let savedY = UserDefaults.standard.double(forKey: "overlay_y")
            let mascotSize = CGFloat(currentSizePixels)
            let statsOrigin: CGPoint
            if standaloneX > 0 || standaloneY > 0 {
                statsOrigin = CGPoint(x: standaloneX, y: standaloneY)
            } else if savedX > 0 || savedY > 0 {
                let mascotMidX = savedX + mascotSize / 2
                statsOrigin = CGPoint(
                    x: mascotMidX - finalWidth / 2,
                    y: savedY + mascotSize + 4
                )
            } else {
                statsOrigin = CGPoint(
                    x: screen.maxX - finalWidth - 40,
                    y: screen.minY + 40
                )
            }
            statsRect = NSRect(origin: statsOrigin, size: CGSize(width: finalWidth, height: finalHeight))
        }
        let newStatsPanel = OverlayPanel(contentRect: statsRect)
        newStatsPanel.isMovableByWindowBackground = true  // Draggable!
        newStatsPanel.contentView = statsController.view
        newStatsPanel.contentViewController = statsController

        // Right-click to show standalone context menu
        newStatsPanel.onRightClick = { [weak self] point in
            self?.showStandaloneContextMenu(at: point)
        }

        newStatsPanel.orderFrontRegardless()
        SkyLightOperator.shared.delegateWindow(newStatsPanel)
        self.statsPanel = newStatsPanel

        // Save position when dragged (separate keys — don't overwrite mascot position)
        let moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: newStatsPanel,
            queue: .main
        ) { [weak self, weak newStatsPanel] _ in
            Task { @MainActor in
                guard let origin = newStatsPanel?.frame.origin else { return }
                UserDefaults.standard.set(origin.x, forKey: "standalone_x")
                UserDefaults.standard.set(origin.y, forKey: "standalone_y")
                self?.scheduleHUDReposition()
            }
        }
        workspaceObservers.append(moveObserver)

        // Re-assert on Space switch
        let spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak newStatsPanel, weak self] _ in
            Task { @MainActor in
                newStatsPanel?.orderFrontRegardless()
                self?.permissionPanel?.orderFrontRegardless()
            }
        }
        workspaceObservers.append(spaceObserver)

        // --- Permission panel (above stats, no tail) ---
        permissionHUDConfig = PermissionHUDConfig()
        permissionHUDConfig.onContentSizeChange = { [weak self] _ in
            self?.scheduleHUDReposition()
        }
        let permView = PermissionHUDView(config: permissionHUDConfig)
            .environment(pendingPermissionStore)
            .environment(hotkeyManager)
            .environment(sessionSwitcherStore)
            .environment(sessionStore)
            .environment(sessionFinishedStore)

        let permController = TransparentHostingController(rootView: permView)
        permController.sizingOptions = []

        let permRect = NSRect(
            x: statsRect.midX - 140,
            y: statsRect.maxY + 4,
            width: 280,
            height: 200
        )
        let newPermPanel = OverlayPanel(contentRect: permRect)
        newPermPanel.isMovableByWindowBackground = false
        newPermPanel.contentView = permController.view
        newPermPanel.contentViewController = permController

        pendingPermissionStore.onPendingChange = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self?.scheduleHUDReposition()
            }
        }

        pendingPermissionStore.onRequestTextInputFocus = { [weak self] in
            guard let permPanel = self?.permissionPanel else { return }
            NSApp.activate(ignoringOtherApps: true)
            permPanel.makeKey()
        }

        newPermPanel.orderFrontRegardless()
        SkyLightOperator.shared.delegateWindow(newPermPanel)
        newStatsPanel.addChildWindow(newPermPanel, ordered: .above)

        self.permissionPanel = newPermPanel

        // Set tail to none for standalone mode
        permissionHUDConfig.tailSide = .none
        permissionHUDConfig.tailPercent = 0
    }

    func toggleOverlay() {
        if isOverlayActive {
            hideOverlay()
        } else if let urlString = UserDefaults.standard.string(forKey: "overlay_url"),
                  let url = URL(string: urlString) {
            showOverlay(url: url)
        }
    }

    /// Restore overlay from previous session
    func restoreIfNeeded() {
        // If mascot is disabled, only show standalone permission panel
        if !isOverlayEnabled {
            showPermissionPanelStandalone()
            return
        }

        // Check if we're in a snooze period
        let snoozeEndTimestamp = UserDefaults.standard.double(forKey: "snooze_end_date")
        if snoozeEndTimestamp > 0 {
            let endDate = Date(timeIntervalSince1970: snoozeEndTimestamp)
            if endDate > Date() {
                // Still snoozed — restore config but stay hidden
                if let configData = UserDefaults.standard.data(forKey: "overlay_config"),
                   let config = try? JSONDecoder().decode(MaskoAnimationConfig.self, from: configData) {
                    snoozedConfig = config
                    snoozeEndDate = endDate
                    isSnoozed = true

                    // Schedule wake for remaining time (skip for indefinite)
                    if endDate != .distantFuture {
                        let remaining = endDate.timeIntervalSinceNow
                        snoozeTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
                            Task { @MainActor [weak self] in
                                self?.wakeFromSnooze()
                            }
                        }
                    }
                }
                return
            } else {
                // Snooze expired while app was closed — clear it
                UserDefaults.standard.removeObject(forKey: "snooze_end_date")
            }
        }

        // Config-based overlay (state machine) takes priority
        if let configData = UserDefaults.standard.data(forKey: "overlay_config"),
           let config = try? JSONDecoder().decode(MaskoAnimationConfig.self, from: configData) {
            showOverlayWithConfig(config)
            // Start auto-hide timer if no sessions active on launch
            updateAutoHideState(isWorking: sessionStore.activeSessions.contains { $0.phase == .running || $0.phase == .compacting })
            return
        }
        // Fall back to URL-based overlay (single video loop)
        guard let urlString = UserDefaults.standard.string(forKey: "overlay_url"),
              let url = URL(string: urlString) else { return }
        showOverlay(url: url)
        // Start auto-hide timer if no sessions active on launch
        updateAutoHideState(isWorking: sessionStore.activeSessions.contains { $0.phase == .running || $0.phase == .compacting })
    }

    // MARK: - Private

    private func cancelSnooze() {
        snoozeTimer?.invalidate()
        snoozeTimer = nil
        snoozedConfig = nil
        snoozeEndDate = nil
        isSnoozed = false
        UserDefaults.standard.removeObject(forKey: "snooze_end_date")
    }

    // MARK: - Context Menu

    /// Set the dialog scale and reposition.
    func setDialogScale(_ scale: Double) {
        permissionHUDConfig.scale = CGFloat(scale)
        permissionHUDConfig.updateScaledSize()
        scheduleHUDReposition()
    }

    /// Show/hide the preview dialog for scale adjustment.
    func setDialogPreview(_ show: Bool) {
        permissionHUDConfig.showPreview = show
        permissionPanel?.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.scheduleHUDReposition() }
    }

    /// Set the mascot overlay opacity and persist it.
    func setOverlayOpacity(_ value: Double) {
        UserDefaults.standard.set(value, forKey: "overlay_opacity")
        panel?.alphaValue = value
    }

    func showContextMenu(at point: NSPoint) {
        dismissContextMenu()
        let panel = ContextMenuPanel()
        let content = OverlayContextMenuContent(
            onSnooze: { [weak self] minutes in self?.snooze(minutes: minutes) },
            onResize: { [weak self] size in self?.currentSizePixels = size.rawValue },
            onDialogScale: { [weak self] scale in self?.setDialogScale(scale) },
            onDialogPreview: { [weak self] show in self?.setDialogPreview(show) },
            onOpacity: { [weak self] value in self?.setOverlayOpacity(value) },
            onClose: { [weak self] in self?.hideOverlay() },
            onDisable: { [weak self] in self?.disableOverlay() },
            dismiss: { [weak panel] in panel?.dismiss() }
        )
        panel.onDismiss = { [weak self] in self?.setDialogPreview(false) }
        panel.showAt(point: point, mascotFrame: self.panel?.frame, with: content)
        self.contextPanel = panel
    }

    /// Show a lightweight context menu for the standalone stats pill (notification-only mode).
    func showStandaloneContextMenu(at point: NSPoint) {
        dismissContextMenu()
        let menuPanel = ContextMenuPanel()
        let content = StandaloneContextMenuContent(
            onEnableMascot: { [weak self] in
                guard let self else { return }
                // If user dragged the stats pill, update mascot position to match
                if let statsFrame = self.statsPanel?.frame {
                    let mascotSize = CGFloat(self.currentSizePixels)
                    let screen = self.statsPanel?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
                    let mascotX = max(screen.minX, min(statsFrame.midX - mascotSize / 2, screen.maxX - mascotSize))
                    let mascotY = max(screen.minY, min(statsFrame.origin.y - 4 - mascotSize, screen.maxY - mascotSize))
                    UserDefaults.standard.set(mascotX, forKey: "overlay_x")
                    UserDefaults.standard.set(mascotY, forKey: "overlay_y")
                }
                // Close standalone panels first
                self.permissionPanel?.close()
                self.permissionPanel = nil
                self.statsPanel?.close()
                self.statsPanel = nil
                for observer in self.workspaceObservers {
                    NotificationCenter.default.removeObserver(observer)
                    NSWorkspace.shared.notificationCenter.removeObserver(observer)
                }
                self.workspaceObservers.removeAll()
                self.enableOverlay()
                self.restoreIfNeeded()
            },
            onOpenDashboard: {
                AppDelegate.showDashboard()
            },
            onClose: { [weak self] in
                self?.hideStandalone()
            },
            dismiss: { [weak menuPanel] in menuPanel?.dismiss() }
        )
        menuPanel.showAt(point: point, mascotFrame: statsPanel?.frame, with: content)
        self.contextPanel = menuPanel
    }

    func dismissContextMenu() {
        contextPanel?.dismiss()
        contextPanel = nil
    }

    /// Close standalone panels (stats + permission) entirely.
    private func hideStandalone() {
        for observer in workspaceObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        permissionPanel?.close()
        permissionPanel = nil
        statsPanel?.close()
        statsPanel = nil
    }

    // MARK: - Session Switcher (rendered inside permission panel)

    /// Trigger permission panel resize when session switcher opens/updates/closes.
    /// The SessionSwitcherView is rendered inside PermissionHUDView — no separate panel needed.
    func showSessionSwitcher() {
        // The SessionSwitcherView lives inside the permission panel.
        // Ensure the panel is visible and re-sync after SwiftUI renders.
        permissionPanel?.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.scheduleHUDReposition() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.scheduleHUDReposition() }
    }

    func updateSessionSwitcher() {
        scheduleHUDReposition()
    }

    func dismissSessionSwitcher() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.scheduleHUDReposition() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.scheduleHUDReposition() }
    }

    func repositionForToast() {
        permissionPanel?.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.scheduleHUDReposition() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.scheduleHUDReposition() }
    }

    // MARK: - Snooze Toast

    private func showSnoozeToast(minutes: Int) {
        guard let mascotPanel = panel else { return }
        let mascotFrame = mascotPanel.frame

        let message: String
        if minutes == 0 {
            message = "Snoozed"
        } else if minutes < 60 {
            message = "Snoozed for \(minutes) min"
        } else {
            message = "Snoozed for \(minutes / 60) hour\(minutes >= 120 ? "s" : "")"
        }

        let toastView = Text(message)
            .font(Constants.heading(size: 13, weight: .medium))
            .foregroundStyle(Constants.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Constants.surfaceWhite)
            .clipShape(RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall))
            .overlay(
                RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall)
                    .stroke(Constants.border, lineWidth: 1)
            )
            .shadow(color: Constants.cardShadowColor, radius: 4, x: 0, y: 2)

        let toastPanel = OverlayPanel(contentRect: NSRect(
            x: mascotFrame.midX - 80,
            y: mascotFrame.midY - 16,
            width: 160,
            height: 32
        ))
        toastPanel.isMovableByWindowBackground = false

        let controller = TransparentHostingController(rootView: toastView)
        toastPanel.contentView = controller.view
        toastPanel.contentViewController = controller

        // Size to fit
        let fittingSize = controller.view.fittingSize
        toastPanel.setFrame(NSRect(
            x: mascotFrame.midX - fittingSize.width / 2,
            y: mascotFrame.midY - fittingSize.height / 2,
            width: fittingSize.width,
            height: fittingSize.height
        ), display: true)

        toastPanel.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            toastPanel.close()
        }
    }

    /// Re-apply window level and bring to front without stealing focus.
    private func reassertPanel() {
        guard let panel else { return }
        panel.level = .screenSaver
        panel.orderFrontRegardless()
        if let statsPanel {
            statsPanel.level = .screenSaver
            statsPanel.orderFrontRegardless()
        }
        if let permissionPanel {
            permissionPanel.level = .screenSaver
            permissionPanel.orderFrontRegardless()
        }
    }

    private func resizePanelToPixels(_ pixels: Int) {
        guard let panel else { return }
        let side = CGFloat(pixels)
        let frame = panel.frame
        let newFrame = NSRect(
            x: frame.origin.x,
            y: frame.origin.y - (side - frame.height),
            width: side,
            height: side
        )
        #if DEBUG
        PerfMonitor.shared.measure(.setFrame, threshold: 16) {
            panel.setFrame(newFrame, display: true, animate: true)
        }
        #else
        panel.setFrame(newFrame, display: true, animate: true)
        #endif
        scheduleHUDReposition()
    }

    /// Resize panel instantly during drag — no animation, no UserDefaults save.
    func resizePanelLive(_ pixels: Int) {
        guard let panel else { return }
        let side = CGFloat(pixels)
        let frame = panel.frame
        let newFrame = NSRect(
            x: frame.origin.x,
            y: frame.origin.y - (side - frame.height),
            width: side,
            height: side
        )
        // Kill all implicit animations for instant feedback
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(newFrame, display: true, animate: false)
        scheduleHUDReposition()
        CATransaction.commit()
    }

    /// Position stats panel directly above mascot, or at bottom-right in standalone mode.
    private func repositionStats() {
        guard let statsPanel else { return }

        if let panel {
            // Mascot mode: center above mascot
            let mascotFrame = panel.frame
            let statsSize = statsPanel.frame.size
            let x = mascotFrame.midX - statsSize.width / 2
            let y = mascotFrame.maxY + 4
            statsPanel.setFrameOrigin(CGPoint(x: x, y: y))
        }
        // Standalone mode: stats stay at their initial position
    }

    /// Measure permission content, resize panel, and smart-position it.
    /// Tries above → right → left → below mascot. In standalone mode, positions at bottom-right.
    private func syncPermissionPanel() {
        #if DEBUG
        PerfMonitor.shared.track(.syncPermissionPanel)
        #endif
        guard let permissionPanel else { return }

        let contentSize = permissionHUDConfig.contentSize
        // Skip if no content (no permissions AND no session switcher)
        if contentSize.height <= 10 { return }

        let permSize = CGSize(width: max(contentSize.width, 280), height: contentSize.height)

        // Standalone mode — no mascot panel, position above the draggable stats pill
        guard let panel else {
            if let statsPanel {
                let statsFrame = statsPanel.frame
                let origin = CGPoint(
                    x: statsFrame.midX - permSize.width / 2,
                    y: statsFrame.maxY + 4
                )
                // Clamp to screen
                let screen = statsPanel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
                let clampedX = max(screen.minX, min(origin.x, screen.maxX - permSize.width))
                let clampedY = min(origin.y, screen.maxY - permSize.height)
                permissionPanel.setFrame(NSRect(origin: CGPoint(x: clampedX, y: clampedY), size: permSize), display: true)
            } else {
                let screen = permissionPanel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
                let origin = CGPoint(x: screen.maxX - permSize.width - 20, y: screen.minY + 80)
                permissionPanel.setFrame(NSRect(origin: origin, size: permSize), display: true)
            }
            permissionHUDConfig.tailSide = .none
            permissionHUDConfig.tailPercent = 0
            return
        }

        let mascotFrame = panel.frame
        let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let gap: CGFloat = 4
        let statsTop = statsPanel?.frame.maxY ?? mascotFrame.maxY

        var origin = CGPoint.zero
        var tailSide: TailSide = .bottom
        var tailPercent: CGFloat = 0.80

        // 1. ABOVE (preferred) — directly above stats panel
        let aboveY = statsTop + gap
        if aboveY + permSize.height <= screen.maxY {
            origin = CGPoint(
                x: max(screen.minX, min(mascotFrame.midX - permSize.width / 2, screen.maxX - permSize.width)),
                y: aboveY
            )
            tailSide = .bottom
            tailPercent = (mascotFrame.midX - origin.x) / permSize.width
        }
        // 2. Side placement — prefer toward screen center
        else {
            let leftX = mascotFrame.minX - permSize.width - gap
            let rightX = mascotFrame.maxX + gap
            let leftFits = leftX >= screen.minX
            let rightFits = rightX + permSize.width <= screen.maxX
            let preferLeft = mascotFrame.midX > screen.midX

            if (preferLeft && leftFits) || (!rightFits && leftFits) {
                let y = max(screen.minY, min(statsTop - permSize.height, screen.maxY - permSize.height))
                origin = CGPoint(x: leftX, y: y)
                tailSide = .right
                tailPercent = 1.0 - ((mascotFrame.midY - origin.y) / permSize.height)
            } else if rightFits {
                let y = max(screen.minY, min(statsTop - permSize.height, screen.maxY - permSize.height))
                origin = CGPoint(x: rightX, y: y)
                tailSide = .left
                tailPercent = 1.0 - ((mascotFrame.midY - origin.y) / permSize.height)
            }
            // 3. BELOW (fallback)
            else {
                let belowY = mascotFrame.minY - permSize.height - gap
                origin = CGPoint(
                    x: max(screen.minX, min(mascotFrame.midX - permSize.width / 2, screen.maxX - permSize.width)),
                    y: max(screen.minY, belowY)
                )
                tailSide = .top
                tailPercent = (mascotFrame.midX - origin.x) / permSize.width
            }
        }

        // Clamp tail percent
        tailPercent = max(0.15, min(tailPercent, 0.85))

        #if DEBUG
        PerfMonitor.shared.measure(.setFrame, threshold: 16) {
            permissionPanel.setFrame(NSRect(origin: origin, size: permSize), display: true)
        }
        #else
        permissionPanel.setFrame(NSRect(origin: origin, size: permSize), display: true)
        #endif
        permissionHUDConfig.tailSide = tailSide
        permissionHUDConfig.tailPercent = tailPercent
    }

    /// Reposition all HUD panels.
    private func repositionHUD() {
        repositionStats()
        syncPermissionPanel()
    }

    /// Coalesced HUD reposition — defers setFrame to the next run loop tick
    /// to break recursive layout cycles (setFrame → SwiftUI layout → onContentSizeChange → setFrame).
    private func scheduleHUDReposition() {
        guard !hudRepositionScheduled else { return }
        hudRepositionScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hudRepositionScheduled = false
            self.repositionStats()
            self.syncPermissionPanel()
        }
    }

    private func savePosition() {
        guard let panel else { return }
        UserDefaults.standard.set(panel.frame.origin.x, forKey: "overlay_x")
        UserDefaults.standard.set(panel.frame.origin.y, forKey: "overlay_y")
    }

    private func setupObservers(for targetPanel: OverlayPanel) {
        // Observe position changes to persist
        let moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: targetPanel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.savePosition() }
        }
        workspaceObservers.append(moveObserver)

        // Re-assert panel when switching Spaces
        let spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reassertPanel() }
        }
        workspaceObservers.append(spaceObserver)

        // Re-assert panel when another app activates (Cmd+Tab)
        let appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reassertPanel() }
        }
        workspaceObservers.append(appObserver)
    }
}

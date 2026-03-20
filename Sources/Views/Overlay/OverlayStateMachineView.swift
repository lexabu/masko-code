import SwiftUI
import AVKit
import AppKit

// MARK: - Mascot Video View (fixed-size panel, never moves)

/// Just the video player with context menu and tap gesture.
/// Lives in its own NSPanel that never changes size.
struct OverlayStateMachineView: View {
    let stateMachine: OverlayStateMachine
    let onClose: () -> Void
    let onResize: (OverlaySize) -> Void
    let onDragResize: (Int) -> Void
    let onDragResizeEnd: (Int) -> Void
    let onSnooze: (Int) -> Void

    @AppStorage("overlay_size") private var currentSizePixels: Int = OverlaySize.medium.rawValue
    @AppStorage("overlay_resize_mode") private var resizeMode = false

    var body: some View {
        #if DEBUG
        let _ = Self._printChanges()
        let _ = PerfMonitor.shared.track(.viewBodyStateMachine)
        #endif
        ZStack(alignment: .bottomTrailing) {
            StateMachineVideoPlayer(
                url: stateMachine.currentVideoURL,
                isLoop: stateMachine.isLoopVideo,
                rate: stateMachine.currentPlaybackRate,
                stateMachine: stateMachine
            )
            .onTapGesture {
                stateMachine.handleClick()
            }

            if resizeMode {
                ResizeHandle(
                    currentSize: currentSizePixels,
                    onDrag: onDragResize,
                    onDragEnd: { size in
                        onDragResizeEnd(size)
                        resizeMode = false
                    }
                )
                .frame(width: 32, height: 32)
            }
        }
    }
}

// MARK: - Stats HUD View (fixed panel directly above mascot)

/// Stats pill and debug HUD. Lives in its own panel that never repositions.
struct StatsHUDView: View {
    let stateMachine: OverlayStateMachine

    @AppStorage("overlay_show_debug") private var showDebug = false
    @AppStorage("overlay_show_stats") private var showStats = true

    var body: some View {
        #if DEBUG
        let _ = Self._printChanges()
        let _ = PerfMonitor.shared.track(.viewBodyStatsHUD)
        #endif
        VStack(spacing: 4) {
            if showDebug {
                DebugHUD(stateMachine: stateMachine)
            }

            #if DEBUG
            if showDebug {
                PerfOverlayView()
            }
            #endif

            if showStats {
                StatsOverlayView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .bottom)
    }
}

// MARK: - Permission HUD View (adaptive panel, repositions for screen edges)

/// Permission prompts in a speech bubble. Lives in its own panel that adapts position.
@Observable
final class PermissionHUDConfig {
    var tailSide: TailSide = .bottom
    var tailPercent: CGFloat = 0.80
    var onContentSizeChange: ((CGSize) -> Void)?
    var showPreview = false
    var scale: CGFloat {
        get {
            let v = UserDefaults.standard.double(forKey: "permission_panel_scale")
            return v > 0 ? CGFloat(v) : 1.0
        }
        set {
            let clamped = max(0.8, min(newValue, 2.5))
            UserDefaults.standard.set(Double(clamped), forKey: "permission_panel_scale")
        }
    }

    /// Unscaled content size measured by GeometryReader.
    var unscaledSize: CGSize = CGSize(width: 280, height: 200)

    /// Scaled content size used for panel frame.
    var contentSize: CGSize = CGSize(width: 280, height: 200) {
        didSet {
            guard abs(contentSize.width - oldValue.width) > 2
               || abs(contentSize.height - oldValue.height) > 2 else { return }
            onContentSizeChange?(contentSize)
        }
    }

    func updateScaledSize() {
        contentSize = CGSize(
            width: unscaledSize.width * scale,
            height: unscaledSize.height * scale
        )
    }
}

struct PermissionHUDView: View {
    let config: PermissionHUDConfig
    @Environment(SessionSwitcherStore.self) var sessionSwitcherStore
    @Environment(GlobalHotkeyManager.self) var hotkeyManager
    @Environment(SessionFinishedStore.self) var sessionFinishedStore

    var body: some View {
        VStack(spacing: 4) {
            if config.showPreview {
                DialogScalePreview()
            }
            SessionSwitcherView()
            SessionFinishedToastView()
            PermissionStackView()
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 280)
        .background(GeometryReader { geo in
            Color.clear
                .onAppear {
                    config.unscaledSize = geo.size
                    config.updateScaledSize()
                }
                .onChange(of: geo.size) { _, newSize in
                    config.unscaledSize = newSize
                    config.updateScaledSize()
                }
        })
        .scaleEffect(config.scale, anchor: .topLeading)
        .frame(
            width: config.unscaledSize.width * config.scale,
            height: config.unscaledSize.height * config.scale,
            alignment: .topLeading
        )
        .environment(\.speechBubbleTailSide, config.tailSide)
        .environment(\.speechBubbleTailPercent, config.tailPercent)
    }
}

// MARK: - Debug HUD

/// Semi-transparent overlay showing state machine status
struct DebugHUD: View {
    let stateMachine: OverlayStateMachine

    var body: some View {
        #if DEBUG
        let _ = Self._printChanges()
        let _ = PerfMonitor.shared.track(.viewBodyDebugHUD)
        #endif
        VStack(alignment: .leading, spacing: 2) {
            Text("\(stateMachine.currentNodeName) (\(phaseLabel))")
                .fontWeight(.bold)

            if let lastInput = stateMachine.lastInputChange {
                let ago = timeAgo(stateMachine.lastInputTime)
                Text("\(lastInput) \(ago)")
                    .foregroundStyle(.white.opacity(0.7))
            }

            if let result = stateMachine.lastMatchResult {
                Text(result)
                    .foregroundStyle(result.contains("Matched") ? .green : .orange)
            }

            if !stateMachine.availableEdges.isEmpty {
                Divider().background(.white.opacity(0.3))
                ForEach(stateMachine.availableEdges, id: \.self) { edge in
                    Text(edge)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.green)
        .padding(6)
        .background(Color.black.opacity(0.6))
        .cornerRadius(4)
        .padding(4)
        .allowsHitTesting(false)
    }

    private var phaseLabel: String {
        switch stateMachine.phase {
        case .idle: return "idle"
        case .looping: return "looping"
        case .transitioning: return "transitioning"
        }
    }

    private func timeAgo(_ date: Date?) -> String {
        guard let date else { return "" }
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 1 { return "now" }
        if seconds < 60 { return "\(seconds)s ago" }
        return "\(seconds / 60)m ago"
    }
}

// MARK: - NSViewRepresentable AVPlayer

/// Plays video URLs from the state machine using an A/B double-buffer.
/// Two AVPlayerLayers exist permanently — opacity swap on isReadyForDisplay
/// guarantees frame-perfect transitions with no flicker.
struct StateMachineVideoPlayer: NSViewRepresentable {
    let url: URL?
    let isLoop: Bool
    let rate: Float
    let stateMachine: OverlayStateMachine

    func makeNSView(context: Context) -> NSView {
        let container = PlayerContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.layer?.isOpaque = false

        // Create both layers upfront
        let layerA = AVPlayerLayer()
        layerA.videoGravity = .resizeAspect
        layerA.backgroundColor = .clear
        layerA.isOpaque = false
        layerA.opacity = 1

        let layerB = AVPlayerLayer()
        layerB.videoGravity = .resizeAspect
        layerB.backgroundColor = .clear
        layerB.isOpaque = false
        layerB.opacity = 0

        if let containerLayer = container.layer {
            containerLayer.addSublayer(layerA)
            containerLayer.addSublayer(layerB)
            layerA.frame = containerLayer.bounds
            layerB.frame = containerLayer.bounds
        }

        context.coordinator.container = container
        context.coordinator.stateMachine = stateMachine
        context.coordinator.layerA = layerA
        context.coordinator.layerB = layerB

        // Initial load
        if let url {
            context.coordinator.loadVideo(url: url, loop: isLoop, rate: rate)
        }

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator

        if url != coordinator.currentURL || isLoop != coordinator.currentLoop {
            if let url {
                coordinator.loadVideo(url: url, loop: isLoop, rate: rate)
            }
        } else if rate != coordinator.currentRate {
            // Rate changed without URL change (e.g. loop speed update)
            coordinator.currentRate = rate
            coordinator.activePlayer?.rate = rate
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject {
        var container: PlayerContainerView?
        var stateMachine: OverlayStateMachine?

        // A/B double-buffer
        var layerA: AVPlayerLayer?
        var layerB: AVPlayerLayer?
        var playerA: AVPlayer?
        var playerB: AVPlayer?
        private var activeIsA = true

        var currentURL: URL?
        var currentLoop = true
        var currentRate: Float = 1.0
        private var endObserver: NSObjectProtocol?
        private var readyObserver: NSKeyValueObservation?

        var activePlayer: AVPlayer? { activeIsA ? playerA : playerB }
        private var activeLayer: AVPlayerLayer? { activeIsA ? layerA : layerB }

        private func releasePlayer(_ player: inout AVPlayer?) {
            guard let p = player else { return }
            p.pause()
            p.replaceCurrentItem(with: nil)
            #if DEBUG
            Task { @MainActor in PerfMonitor.shared.avPlayerDestroyed() }
            #endif
            player = nil
        }

        func loadVideo(url: URL, loop: Bool, rate: Float = 1.0) {
            // Clean up pending observers
            if let obs = endObserver {
                NotificationCenter.default.removeObserver(obs)
                endObserver = nil
            }
            readyObserver?.invalidate()
            readyObserver = nil

            currentURL = url
            currentLoop = loop
            currentRate = rate

            let isFirstLoad = playerA == nil && playerB == nil
            let newPlayer = AVPlayer(url: url)
            newPlayer.isMuted = true
            #if DEBUG
            Task { @MainActor in PerfMonitor.shared.avPlayerCreated() }
            #endif

            // Load onto the inactive buffer, releasing any old player there
            let targetLayer: AVPlayerLayer?
            if isFirstLoad {
                // First video — load directly onto A
                playerA = newPlayer
                layerA?.player = newPlayer
                layerA?.opacity = 1
                activeIsA = true
                targetLayer = layerA
            } else if activeIsA {
                // Release old inactive buffer player before replacing
                releasePlayer(&playerB)
                playerB = newPlayer
                layerB?.player = newPlayer
                targetLayer = layerB
            } else {
                releasePlayer(&playerA)
                playerA = newPlayer
                layerA?.player = newPlayer
                targetLayer = layerA
            }

            guard let targetLayer else { return }

            if !isFirstLoad {
                // Wait for the new layer to have a decoded frame, then swap
                let oldPlayer = activePlayer
                let oldLayer = activeLayer
                readyObserver = targetLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
                    guard layer.isReadyForDisplay else { return }
                    DispatchQueue.main.async {
                        guard let self else { return }
                        // Instant opacity swap — no implicit animation
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        targetLayer.opacity = 1
                        oldLayer?.opacity = 0
                        CATransaction.commit()
                        oldPlayer?.pause()
                        oldPlayer?.replaceCurrentItem(with: nil)
                        self.activeIsA.toggle()
                    }
                    self?.readyObserver?.invalidate()
                    self?.readyObserver = nil
                }
            }

            // End-of-video observer
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: newPlayer.currentItem,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                if self.currentLoop {
                    self.activePlayer?.seek(to: .zero)
                    self.activePlayer?.play()
                    if self.currentRate != 1.0 {
                        self.activePlayer?.rate = self.currentRate
                    }
                    Task { @MainActor in
                        self.stateMachine?.handleLoopCycleCompleted()
                    }
                } else {
                    Task { @MainActor in
                        self.stateMachine?.handleVideoEnded()
                    }
                }
            }

            newPlayer.play()
            if rate != 1.0 {
                newPlayer.rate = rate
            }
        }

        deinit {
            if let obs = endObserver {
                NotificationCenter.default.removeObserver(obs)
            }
            readyObserver?.invalidate()
            playerA?.pause()
            playerB?.pause()
            #if DEBUG
            let hadA = playerA != nil
            let hadB = playerB != nil
            Task { @MainActor in
                if hadA { PerfMonitor.shared.avPlayerDestroyed() }
                if hadB { PerfMonitor.shared.avPlayerDestroyed() }
            }
            #endif
        }
    }
}

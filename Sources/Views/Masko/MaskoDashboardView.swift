import SwiftUI
import AppKit

// MARK: - Native NSTextView wrapper (SwiftUI TextEditor is broken in sheets on macOS)

struct NativeTextEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var font: NSFont = .monospacedSystemFont(ofSize: 11, weight: .regular)

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.font = font
        textView.textColor = .labelColor
        textView.backgroundColor = .white
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 6, height: 8)

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        // Force first responder after a tick
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            textView.window?.makeFirstResponder(textView)
        }

        context.coordinator.textView = textView
        context.coordinator.updatePlaceholder(text)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        context.coordinator.updatePlaceholder(text)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, placeholder: placeholder)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        let placeholder: String
        weak var textView: NSTextView?
        private var placeholderView: NSTextField?

        init(text: Binding<String>, placeholder: String) {
            self._text = text
            self.placeholder = placeholder
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text = tv.string
            updatePlaceholder(tv.string)
        }

        func updatePlaceholder(_ currentText: String) {
            guard let textView else { return }

            if currentText.isEmpty && placeholderView == nil {
                let label = NSTextField(labelWithString: placeholder)
                label.font = textView.font
                label.textColor = .placeholderTextColor
                label.translatesAutoresizingMaskIntoConstraints = false
                label.isEditable = false
                label.isBezeled = false
                label.drawsBackground = false
                textView.addSubview(label)
                NSLayoutConstraint.activate([
                    label.topAnchor.constraint(equalTo: textView.topAnchor, constant: 8),
                    label.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 10),
                ])
                placeholderView = label
            } else if !currentText.isEmpty {
                placeholderView?.removeFromSuperview()
                placeholderView = nil
            }
        }
    }
}

// MARK: - Context Menu ("..." button triggers NSMenu via NSViewRepresentable)

private final class CallbackMenuItem: NSMenuItem {
    private let callback: () -> Void
    init(title: String, icon: String, callback: @escaping () -> Void) {
        self.callback = callback
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
        self.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() {
        DispatchQueue.main.async { [self] in callback() }
    }
}

/// Invisible NSView that shows an NSMenu when triggered by the "..." button.
/// Right-click is handled by SwiftUI's .contextMenu modifier instead.
private struct CardMenuHost: NSViewRepresentable {
    let trigger: Int
    let onViewGraph: () -> Void
    let onEditJSON: () -> Void
    let onCopyJSON: () -> Void
    let onDelete: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let c = context.coordinator
        c.hostView = nsView
        c.actions = (onViewGraph, onEditJSON, onCopyJSON, onDelete)
        if trigger != c.lastTrigger {
            c.lastTrigger = trigger
            if trigger > 0 { c.showMenuFromButton() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var hostView: NSView?
        var actions: (() -> Void, () -> Void, () -> Void, () -> Void)?
        var lastTrigger = 0

        private func buildMenu() -> NSMenu {
            guard let actions else { return NSMenu() }
            let menu = NSMenu()
            menu.addItem(CallbackMenuItem(title: "View Graph", icon: "rectangle.3.group", callback: actions.0))
            menu.addItem(CallbackMenuItem(title: "Edit JSON", icon: "curlybraces", callback: actions.1))
            menu.addItem(CallbackMenuItem(title: "Copy JSON", icon: "doc.on.doc", callback: actions.2))
            menu.addItem(.separator())
            let del = CallbackMenuItem(title: "Delete", icon: "trash", callback: actions.3)
            del.attributedTitle = NSAttributedString(
                string: "Delete",
                attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.systemFont(ofSize: 13)]
            )
            menu.addItem(del)
            return menu
        }

        func showMenuFromButton() {
            guard let hostView else { return }
            let pt = NSPoint(x: hostView.bounds.maxX - 10, y: hostView.bounds.minY + 10)
            buildMenu().popUp(positioning: nil, at: pt, in: hostView)
        }
    }
}

// MARK: - Dashboard

struct MaskoDashboardView: View {
    @Environment(AppStore.self) var appStore
    @Environment(OverlayManager.self) var overlayManager

    @State private var showingAddSheet = false
    @State private var selectedMascotId: UUID?
    @State private var jsonText = ""
    @State private var parseError: String?

    private var showingDetail: Binding<Bool> {
        Binding(
            get: { selectedMascotId != nil },
            set: { if !$0 { selectedMascotId = nil } }
        )
    }

    private var snoozeLabel: String {
        guard let end = overlayManager.snoozeEndDate else { return "Snoozed" }
        if end == .distantFuture { return "Snoozed" }
        let remaining = Int(end.timeIntervalSinceNow)
        if remaining <= 0 { return "Snoozed" }
        if remaining < 60 { return "Snoozed — <1 min left" }
        let minutes = remaining / 60
        if minutes < 60 { return "Snoozed — \(minutes) min left" }
        let hours = minutes / 60
        let mins = minutes % 60
        if mins == 0 { return "Snoozed — \(hours)h left" }
        return "Snoozed — \(hours)h \(mins)m left"
    }

    var body: some View {
        if let mascotId = selectedMascotId {
            MascotDetailView(
                mascotId: mascotId,
                isPresented: showingDetail
            )
        } else {
            listBody
        }
    }

    private var listBody: some View {
        VStack(spacing: 0) {
            // Inline header
            HStack(spacing: 10) {
                Text("Mascots")
                    .font(Constants.heading(size: 18, weight: .semibold))
                    .foregroundColor(Constants.textPrimary)

                Spacer()

                if overlayManager.isSnoozed {
                    Button(action: { overlayManager.wakeFromSnooze() }) {
                        HStack(spacing: 5) {
                            Image(systemName: "moon.zzz.fill")
                                .font(.system(size: 12))
                            Text(snoozeLabel)
                                .font(Constants.body(size: 13, weight: .medium))
                        }
                        .foregroundColor(Constants.orangePrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Constants.orangePrimary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall))
                        .overlay(
                            RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall)
                                .stroke(Constants.orangePrimary.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                } else if overlayManager.isOverlayActive {
                    Button(action: { overlayManager.hideOverlay() }) {
                        HStack(spacing: 5) {
                            Image(systemName: "eye.slash")
                                .font(.system(size: 12))
                            Text("Hide")
                                .font(Constants.body(size: 13, weight: .medium))
                        }
                        .foregroundColor(Constants.textMuted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Constants.surfaceWhite)
                        .clipShape(RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall))
                        .overlay(
                            RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall)
                                .stroke(Constants.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }

                Button(action: { showingAddSheet = true }) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Constants.orangePrimary)
                        .frame(width: 32, height: 32)
                        .background(Constants.surfaceWhite)
                        .clipShape(RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall))
                        .overlay(
                            RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall)
                                .stroke(Constants.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            mascotListView
        }
        .background(Constants.lightBackground)
        .navigationTitle("")
        .sheet(isPresented: $showingAddSheet) {
            addMascotSheet
        }
    }

    // MARK: - Mascot List

    private var mascotListView: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 16)
            ], spacing: 16) {
                ForEach(appStore.mascotStore.mascots) { mascot in
                    MascotCard(
                        mascot: mascot,
                        isActive: overlayManager.isOverlayActive,
                        onTap: {
                            selectedMascotId = mascot.id
                        },
                        onActivate: {
                            overlayManager.showOverlayWithConfig(mascot.config)
                        },
                        onSaveConfig: { newConfig in
                            appStore.mascotStore.updateConfig(mascotId: mascot.id, config: newConfig)
                        },
                        onDelete: {
                            appStore.mascotStore.remove(id: mascot.id)
                        }
                    )
                }

            }
            .padding(20)

            // CTA banner
            createMascotBanner
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
    }

    private var createMascotBanner: some View {
        Button(action: {
            NSWorkspace.shared.open(URL(string: "\(Constants.maskoBaseURL)/collections")!)
        }) {
            HStack(spacing: 12) {
                Image(systemName: "paintbrush.pointed.fill")
                    .font(.system(size: 16))
                    .foregroundColor(Constants.orangePrimary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Create your own mascot")
                        .font(Constants.heading(size: 14, weight: .semibold))
                        .foregroundColor(Constants.textPrimary)
                    Text("Open masko.ai, go to Canvas, and pick the Claude Code template")
                        .font(Constants.body(size: 12))
                        .foregroundColor(Constants.textMuted)
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Constants.orangePrimary)
            }
            .padding(14)
            .background(Constants.orangePrimary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: Constants.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Constants.cornerRadius)
                    .stroke(Constants.orangePrimary.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Add Sheet

    private var addMascotSheet: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Import JSON")
                    .font(Constants.heading(size: 18, weight: .semibold))
                    .foregroundColor(Constants.textPrimary)
                Spacer()
                Button(action: {
                    showingAddSheet = false
                    jsonText = ""
                    parseError = nil
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Constants.textMuted)
                }
                .buttonStyle(.plain)
            }

            Text("Paste config JSON exported from the masko.ai canvas editor")
                .font(Constants.body(size: 13))
                .foregroundColor(Constants.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)

            NativeTextEditor(text: $jsonText, placeholder: "Paste JSON here...")
                .clipShape(RoundedRectangle(cornerRadius: Constants.cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Constants.cornerRadius)
                        .stroke(Constants.border, lineWidth: 1)
                )

            if let parseError {
                Text(parseError)
                    .font(Constants.body(size: 11))
                    .foregroundColor(Color(.sRGB, red: 220/255, green: 38/255, blue: 38/255))
            }

            Button(action: addMascot) {
                Text("Import")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(BrandPrimaryButton(
                isDisabled: jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ))
            .disabled(jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(20)
        .frame(width: 460, height: 320)
        .background(Constants.lightBackground)
    }

    // MARK: - Actions

    private func addMascot() {
        parseError = nil
        let trimmed = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let data = trimmed.data(using: .utf8) else {
            parseError = "Invalid text encoding"
            return
        }

        do {
            let config = try JSONDecoder().decode(MaskoAnimationConfig.self, from: data)
            appStore.mascotStore.add(config: config)
            jsonText = ""
            parseError = nil
            showingAddSheet = false
        } catch {
            parseError = "Invalid config JSON: \(error.localizedDescription)"
        }
    }
}

// MARK: - Mascot Card

struct MascotCard: View {
    let mascot: SavedMascot
    let isActive: Bool
    let onTap: () -> Void
    let onActivate: () -> Void
    let onSaveConfig: (MaskoAnimationConfig) -> Void
    let onDelete: () -> Void
    @State private var isHovered = false
    @State private var showingJSON = false
    @State private var menuTrigger = 0

    /// First loop edge's video URL — used as a thumbnail preview
    private var thumbnailURL: URL? {
        let loopEdge = mascot.config.edges.first(where: { $0.isLoop })
            ?? mascot.config.edges.first
        guard let urlString = loopEdge?.videos.hevc ?? loopEdge?.videos.webm,
              let url = URL(string: urlString) else { return nil }
        return url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Preview — video thumbnail or fallback (clickable to open detail)
            Button(action: onTap) {
                ZStack {
                    RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall)
                        .fill(Constants.stage)

                    if let url = thumbnailURL {
                        MascotVideoView(url: url)
                            .clipShape(RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall))
                    } else {
                        VStack(spacing: 4) {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 28))
                                .foregroundColor(Constants.orangePrimary.opacity(0.6))
                            Text("\(mascot.config.nodes.count) poses")
                                .font(Constants.body(size: 11))
                                .foregroundColor(Constants.textMuted)
                        }
                    }
                }
                .frame(height: 140)
            }
            .buttonStyle(.plain)
            .padding(12)
            .padding(.bottom, 0)

            VStack(alignment: .leading, spacing: 4) {
                Button(action: onTap) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(mascot.name)
                            .font(Constants.heading(size: 15, weight: .semibold))
                            .foregroundColor(Constants.textPrimary)
                            .lineLimit(1)

                        HStack(spacing: 8) {
                            let nodeCount = mascot.config.nodes.count
                            let edgeCount = mascot.config.edges.count
                            Text("\(nodeCount) node\(nodeCount == 1 ? "" : "s") · \(edgeCount) transition\(edgeCount == 1 ? "" : "s")")
                                .font(Constants.body(size: 12))
                                .foregroundColor(Constants.textMuted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                HStack(spacing: 6) {
                    Button(action: onActivate) {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                            Text("Activate")
                        }
                        .font(Constants.heading(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Constants.orangePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall))
                    }
                    .buttonStyle(.plain)

                    Button(action: { menuTrigger += 1 }) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Constants.textMuted)
                            .frame(width: 36, height: 36)
                            .background(Constants.surfaceWhite)
                            .clipShape(RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall))
                            .overlay(
                                RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall)
                                    .stroke(Constants.border, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .background(Constants.surfaceWhite)
        .clipShape(RoundedRectangle(cornerRadius: Constants.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Constants.cornerRadius)
                .stroke(isHovered ? Constants.orangePrimary.opacity(0.5) : Constants.border, lineWidth: 1)
        )
        .shadow(
            color: isHovered ? Constants.cardHoverShadowColor : Constants.cardShadowColor,
            radius: isHovered ? Constants.cardHoverShadowRadius : Constants.cardShadowRadius,
            x: 0,
            y: isHovered ? Constants.cardHoverShadowY : Constants.cardShadowY
        )
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .contextMenu {
            Button(action: onTap) {
                Label("View Graph", systemImage: "rectangle.3.group")
            }
            Button(action: { showingJSON = true }) {
                Label("Edit JSON", systemImage: "curlybraces")
            }
            Button(action: {
                if let data = try? JSONEncoder.prettyEncoder.encode(mascot.config),
                   let json = String(data: data, encoding: .utf8) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(json, forType: .string)
                }
            }) {
                Label("Copy JSON", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
        .background(
            CardMenuHost(
                trigger: menuTrigger,
                onViewGraph: onTap,
                onEditJSON: { showingJSON = true },
                onCopyJSON: {
                    if let data = try? JSONEncoder.prettyEncoder.encode(mascot.config),
                       let json = String(data: data, encoding: .utf8) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(json, forType: .string)
                    }
                },
                onDelete: onDelete
            )
        )
        .sheet(isPresented: $showingJSON) {
            JSONEditorSheet(
                name: mascot.name,
                config: mascot.config,
                onSave: onSaveConfig,
                isPresented: $showingJSON
            )
        }
    }
}

// MARK: - JSON Viewer

private extension JSONEncoder {
    static let prettyEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

struct JSONEditorSheet: View {
    let name: String
    let config: MaskoAnimationConfig
    let onSave: (MaskoAnimationConfig) -> Void
    @Binding var isPresented: Bool

    @State private var jsonText: String
    @State private var parseError: String?
    @State private var saved = false

    init(name: String, config: MaskoAnimationConfig, onSave: @escaping (MaskoAnimationConfig) -> Void, isPresented: Binding<Bool>) {
        self.name = name
        self.config = config
        self.onSave = onSave
        self._isPresented = isPresented
        // Encode JSON upfront so NativeTextEditor has it from the first render
        let json: String
        if let data = try? JSONEncoder.prettyEncoder.encode(config),
           let str = String(data: data, encoding: .utf8) {
            json = str
        } else {
            json = "// Failed to encode config"
        }
        self._jsonText = State(initialValue: json)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(name)
                    .font(Constants.heading(size: 16, weight: .semibold))
                    .foregroundColor(Constants.textPrimary)
                Spacer()

                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(jsonText, forType: .string)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                        Text("Copy")
                    }
                }
                .buttonStyle(BrandSecondaryButton())

                Button(action: saveJSON) {
                    HStack(spacing: 4) {
                        Image(systemName: saved ? "checkmark" : "square.and.arrow.down")
                        Text(saved ? "Saved" : "Save")
                    }
                }
                .buttonStyle(BrandPrimaryButton())

                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Constants.textMuted)
                }
                .buttonStyle(.plain)
            }

            if let parseError {
                Text(parseError)
                    .font(Constants.body(size: 11))
                    .foregroundColor(Color(.sRGB, red: 220/255, green: 38/255, blue: 38/255))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            NativeTextEditor(text: $jsonText)
                .clipShape(RoundedRectangle(cornerRadius: Constants.cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Constants.cornerRadius)
                        .stroke(Constants.border, lineWidth: 1)
                )
        }
        .padding(20)
        .frame(width: 560, height: 480)
        .background(Constants.lightBackground)
    }

    private func saveJSON() {
        parseError = nil
        saved = false
        let trimmed = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            parseError = "JSON is empty"
            return
        }
        guard let data = trimmed.data(using: .utf8) else {
            parseError = "Invalid text encoding"
            return
        }
        do {
            let newConfig = try JSONDecoder().decode(MaskoAnimationConfig.self, from: data)
            onSave(newConfig)
            parseError = nil
            saved = true
        } catch {
            parseError = "Invalid JSON: \(error.localizedDescription)"
        }
    }
}

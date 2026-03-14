import SwiftUI

struct SessionListView: View {
    @Environment(AppStore.self) var appStore
    @State private var selectedSession: ClaudeSession?

    var body: some View {
        VStack(spacing: 0) {
            if appStore.sessionStore.sessions.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "terminal")
                        .font(.system(size: 36))
                        .foregroundColor(Constants.textMuted)
                    Text("No Sessions")
                        .font(Constants.heading(size: 22, weight: .semibold))
                        .foregroundColor(Constants.textPrimary)
                    Text("Claude Code and Codex sessions will appear here")
                        .font(Constants.body(size: 14))
                        .foregroundColor(Constants.textMuted)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Constants.lightBackground)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(appStore.sessionStore.sessions) { session in
                            SessionRow(
                                session: session,
                                isSelected: selectedSession?.id == session.id
                            )
                            .onTapGesture {
                                if selectedSession?.id == session.id {
                                    // Second tap on selected session: focus terminal
                                    IDETerminalFocus.focusSession(session)
                                } else {
                                    selectedSession = session
                                }
                            }
                        }
                    }
                    .padding(8)
                }
                .background(Constants.lightBackground)
            }
        }
        .background(Constants.lightBackground)
        .navigationTitle("Sessions")
    }
}

// MARK: - Session Row

private struct SessionRow: View {
    let session: ClaudeSession
    let isSelected: Bool
    @State private var isHovered = false
    @State private var isFocusHovered = false

    var body: some View {
        HStack {
            Image(systemName: session.status == .active ? "circle.fill" : "circle")
                .foregroundColor(session.status == .active ? Color.green : Constants.textMuted)
                .font(.caption)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.projectName ?? "Unknown Project")
                    .font(Constants.heading(size: 14, weight: .semibold))
                    .foregroundColor(isSelected ? Constants.orangePrimary : Constants.textPrimary)
                HStack {
                    Text("\(session.eventCount) events")
                        .font(Constants.body(size: 11))
                        .foregroundColor(Constants.textMuted)
                    if let lastEvent = session.lastEventAt {
                        Text("Last: \(lastEvent, style: .relative)")
                            .font(Constants.body(size: 11))
                            .foregroundColor(Constants.textMuted)
                    }
                }
            }

            Spacer()

            if session.status == .active {
                Button {
                    IDETerminalFocus.focusSession(session)
                } label: {
                    Image(systemName: "terminal.fill")
                        .font(.caption2)
                        .foregroundColor(isFocusHovered ? Constants.orangeHover : Constants.orangePrimary)
                }
                .buttonStyle(.plain)
                .help("Switch to terminal")
                .onHover { isFocusHovered = $0 }
            }

            Text(session.status.rawValue.capitalized)
                .font(Constants.body(size: 11, weight: .medium))
                .foregroundColor(session.status == .active ? Color.green : Constants.textMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    session.status == .active
                        ? Color.green.opacity(0.1)
                        : Constants.border,
                    in: Capsule()
                )
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall)
                .fill(isSelected ? Constants.orangePrimarySubtle : (isHovered ? Constants.chip.opacity(0.6) : Color.clear))
        )
        .overlay(
            isSelected
                ? RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall)
                    .strokeBorder(Constants.orangePrimary.opacity(0.3), lineWidth: 1)
                : nil
        )
        .onHover { isHovered = $0 }
    }
}

extension ClaudeSession: Hashable {
    static func == (lhs: ClaudeSession, rhs: ClaudeSession) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

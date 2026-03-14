import SwiftUI

struct ActivityFeedView: View {
    @Environment(AppStore.self) var appStore
    @State private var filterType: HookEventType?
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            HStack {
                Picker("Filter", selection: $filterType) {
                    Text("All Events").tag(nil as HookEventType?)
                    ForEach(HookEventType.allCases) { type in
                        Label(type.displayName, systemImage: type.sfSymbol)
                            .tag(type as HookEventType?)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 200)

                Spacer()

                // Live indicator
                HStack(spacing: 6) {
                    Circle()
                        .fill(appStore.localServer.isRunning ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(appStore.localServer.isRunning ? "Listening on \(appStore.localServer.port)" : "Offline")
                        .font(.caption)
                        .foregroundColor(Constants.textMuted)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Constants.surfaceWhite)

            Divider().overlay(Constants.border)

            if filteredEvents.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "list.bullet")
                        .font(.system(size: 36))
                        .foregroundColor(Constants.textMuted)
                    Text("No Events")
                        .font(Constants.heading(size: 22, weight: .semibold))
                        .foregroundColor(Constants.textPrimary)
                    Text("Claude Code and Codex events will appear here in real-time")
                        .font(Constants.body(size: 14))
                        .foregroundColor(Constants.textMuted)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Constants.lightBackground)
            } else {
                List(filteredEvents) { event in
                    EventRow(event: event)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(Constants.lightBackground)
            }
        }
        .background(Constants.lightBackground)
        .searchable(text: $searchText, prompt: "Search events...")
        .navigationTitle("Activity Feed")
    }

    var filteredEvents: [ClaudeEvent] {
        appStore.eventStore.events
            .filter { event in
                if let filterType { return event.eventType == filterType }
                return true
            }
            .filter { event in
                if searchText.isEmpty { return true }
                return event.toolName?.localizedCaseInsensitiveContains(searchText) == true
                    || event.projectName?.localizedCaseInsensitiveContains(searchText) == true
                    || event.hookEventName.localizedCaseInsensitiveContains(searchText)
            }
    }
}

struct EventRow: View {
    let event: ClaudeEvent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: event.eventType?.sfSymbol ?? "questionmark.circle")
                .font(.system(size: 14))
                .foregroundColor(color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(event.eventType?.displayName ?? event.hookEventName)
                        .font(Constants.heading(size: 14, weight: .semibold))
                        .foregroundColor(Constants.textPrimary)
                    if let toolName = event.toolName {
                        Text(toolName)
                            .font(Constants.body(size: 12))
                            .foregroundColor(Constants.orangePrimary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .overlay(Capsule().stroke(Constants.orangePrimary.opacity(0.25), lineWidth: 1))
                    }
                    if let notificationType = event.notificationType {
                        Text(notificationType)
                            .font(Constants.body(size: 12))
                            .foregroundColor(Constants.orangePrimary)
                    }
                }

                HStack {
                    if let projectName = event.projectName {
                        Text(projectName)
                            .font(Constants.body(size: 11))
                            .foregroundColor(Constants.textMuted)
                    }
                    Spacer()
                    Text(event.receivedAt, style: .relative)
                        .font(Constants.body(size: 11))
                        .foregroundColor(Constants.textMuted)
                }
            }
        }
        .padding(.vertical, 4)
    }

    var color: Color {
        guard let type = event.eventType else { return Constants.textMuted }
        switch type {
        case .notification, .permissionRequest: return Constants.orangePrimary
        case .sessionStart, .subagentStart: return Color.green
        case .sessionEnd, .subagentStop: return Color(.sRGB, red: 220/255, green: 38/255, blue: 38/255)
        case .stop, .taskCompleted: return Constants.orangePrimary
        case .postToolUseFailure: return Color(.sRGB, red: 220/255, green: 38/255, blue: 38/255)
        case .preToolUse, .postToolUse: return Color(.sRGB, red: 147/255, green: 51/255, blue: 234/255)
        default: return Constants.textMuted
        }
    }
}

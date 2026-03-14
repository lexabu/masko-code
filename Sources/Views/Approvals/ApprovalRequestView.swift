import SwiftUI

struct ApprovalRequestView: View {
    @Environment(AppStore.self) var appStore

    var permissionNotifications: [AppNotification] {
        appStore.notificationStore.notifications.filter {
            $0.category == .permissionRequest
        }
    }

    var pendingItems: [AppNotification] {
        permissionNotifications.filter { $0.resolutionOutcome == .pending }
    }

    var historyItems: [AppNotification] {
        permissionNotifications.filter { $0.resolutionOutcome != .pending }
    }

    var body: some View {
        VStack(spacing: 0) {
            if permissionNotifications.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "hand.raised")
                        .font(.system(size: 36))
                        .foregroundColor(Constants.textMuted)
                    Text("No Approvals")
                        .font(Constants.heading(size: 22, weight: .semibold))
                        .foregroundColor(Constants.textPrimary)
                    Text("Permission requests from supported assistants will appear here")
                        .font(Constants.body(size: 14))
                        .foregroundColor(Constants.textMuted)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Constants.lightBackground)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Pending section
                        if !pendingItems.isEmpty {
                            sectionHeader("Pending", count: pendingItems.count)
                            ForEach(pendingItems) { notification in
                                ApprovalRow(notification: notification, isPending: true)
                                    .environment(appStore)
                                Divider().overlay(Constants.border)
                            }
                        }

                        // History section
                        if !historyItems.isEmpty {
                            sectionHeader("History", count: historyItems.count)
                            ForEach(historyItems) { notification in
                                ApprovalRow(notification: notification, isPending: false)
                                    .environment(appStore)
                                Divider().overlay(Constants.border)
                            }
                        }
                    }
                }
                .background(Constants.lightBackground)
            }
        }
        .background(Constants.lightBackground)
        .navigationTitle("Approvals")
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(Constants.heading(size: 12, weight: .semibold))
                .foregroundColor(Constants.textMuted)
                .textCase(.uppercase)
            Text("\(count)")
                .font(Constants.body(size: 11, weight: .medium))
                .foregroundColor(Constants.textMuted)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
}

// MARK: - Approval Row

private struct ApprovalRow: View {
    @Environment(AppStore.self) var appStore
    let notification: AppNotification
    let isPending: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: isPending ? "exclamationmark.triangle.fill" : outcomeIcon)
                .font(.system(size: 14))
                .foregroundColor(isPending ? Constants.orangePrimary : outcomeColor)
                .frame(width: 24)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(notification.title)
                        .font(Constants.heading(size: 14, weight: .semibold))
                        .foregroundColor(Constants.textPrimary)
                    Spacer()
                    if !isPending {
                        outcomeBadge
                    }
                }

                if let body = notification.body {
                    Text(body)
                        .font(Constants.body(size: 13))
                        .foregroundColor(Constants.textMuted)
                        .lineLimit(2)
                }

                HStack {
                    Text(notification.createdAt, style: .relative)
                        .font(Constants.body(size: 11))
                        .foregroundColor(Constants.textMuted)

                    if let resolvedAt = notification.resolvedAt {
                        Text("·")
                            .foregroundColor(Constants.textMuted)
                        Text("resolved ")
                            .font(Constants.body(size: 11))
                            .foregroundColor(Constants.textMuted)
                        + Text(resolvedAt, style: .relative)
                            .font(Constants.body(size: 11))
                            .foregroundColor(Constants.textMuted)
                    }

                    Spacer()

                    if isPending {
                        Button("Dismiss") {
                            appStore.notificationStore.markAsRead(notification.id)
                        }
                        .buttonStyle(BrandGhostButton(color: Constants.orangePrimary))
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Outcome helpers

    private var outcomeIcon: String {
        switch notification.resolutionOutcome {
        case .allowed: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .expired: return "clock.fill"
        case .unknown: return "questionmark.circle"
        case .pending: return "exclamationmark.triangle.fill"
        }
    }

    private var outcomeColor: Color {
        switch notification.resolutionOutcome {
        case .allowed: return Color(.sRGB, red: 22/255, green: 163/255, blue: 74/255)
        case .denied: return Color(.sRGB, red: 220/255, green: 38/255, blue: 38/255)
        case .expired: return Constants.textMuted
        case .unknown: return Constants.textMuted
        case .pending: return Constants.orangePrimary
        }
    }

    @ViewBuilder
    private var outcomeBadge: some View {
        let (label, color) = badgeConfig
        Text(label)
            .font(Constants.body(size: 11, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.10), in: Capsule())
    }

    private var badgeConfig: (String, Color) {
        switch notification.resolutionOutcome {
        case .allowed:
            return ("Allowed", Color(.sRGB, red: 22/255, green: 163/255, blue: 74/255))
        case .denied:
            return ("Denied", Color(.sRGB, red: 220/255, green: 38/255, blue: 38/255))
        case .expired:
            return ("Expired", Constants.textMuted)
        case .unknown:
            return ("Terminal", Constants.textMuted)
        case .pending:
            return ("Pending", Constants.orangePrimary)
        }
    }
}

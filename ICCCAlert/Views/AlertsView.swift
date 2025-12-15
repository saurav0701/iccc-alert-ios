import SwiftUI

struct AlertsView: View {
    @StateObject private var viewModel: AlertsViewModel
    @StateObject private var webSocketService = WebSocketService.shared
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @State private var selectedFilter: AlertFilter = .all
    
    init(authManager: AuthManager) {
        _viewModel = StateObject(wrappedValue: AlertsViewModel(authManager: authManager))
    }
    
    // **FIX**: Get events directly from SubscriptionManager with proper filtering
    var filteredAlerts: [Event] {
        var allEvents: [Event] = []
        
        // Get all events from all subscribed channels
        for channel in subscriptionManager.subscribedChannels {
            let events = subscriptionManager.getEvents(channelId: channel.id)
            allEvents.append(contentsOf: events)
        }
        
        // Sort by timestamp (newest first)
        allEvents.sort { $0.timestamp > $1.timestamp }
        
        // Apply filter
        switch selectedFilter {
        case .all:
            return allEvents
        case .unread:
            // **FIX**: Use proper unread tracking from subscription manager
            return allEvents.filter { event in
                guard let channelName = event.channelName else { return false }
                return subscriptionManager.getUnreadCount(channelId: channelName) > 0
            }
        case .important:
            return allEvents.filter { $0.priority == "high" }
        }
    }
    
    var unreadCount: Int {
        subscriptionManager.subscribedChannels.reduce(0) { total, channel in
            total + subscriptionManager.getUnreadCount(channelId: channel.id)
        }
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Filter Picker
                Picker("Filter", selection: $selectedFilter) {
                    Text("All (\(filteredAlerts.count))").tag(AlertFilter.all)
                    Text("Unread (\(unreadCount))").tag(AlertFilter.unread)
                    Text("Important").tag(AlertFilter.important)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding()
                
                // Connection Status
                if !webSocketService.isConnected {
                    HStack {
                        Image(systemName: "wifi.slash")
                        Text("Disconnected")
                            .font(.caption)
                        Spacer()
                        Button("Reconnect") {
                            webSocketService.connect()
                        }
                        .font(.caption)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.2))
                } else {
                    HStack {
                        Image(systemName: "wifi")
                            .foregroundColor(.green)
                        Text(webSocketService.connectionStatus)
                            .font(.caption)
                            .foregroundColor(.green)
                        Spacer()
                        Text("\(webSocketService.processedCount) events")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.1))
                }
                
                // Alerts List
                if filteredAlerts.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 50))
                            .foregroundColor(.gray)
                        Text("No alerts")
                            .font(.headline)
                        Text(subscriptionManager.subscribedChannels.isEmpty ? 
                             "Subscribe to channels to receive alerts" : 
                             "You're all caught up!")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(filteredAlerts) { alert in
                            AlertRowView(alert: alert) {
                                markAsRead(alert)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Alerts")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        markAllAsRead()
                    }) {
                        Text("Mark All Read")
                            .font(.subheadline)
                    }
                    .disabled(unreadCount == 0)
                }
            }
        }
        .onAppear {
            // Connect WebSocket if not connected
            if !webSocketService.isConnected {
                webSocketService.connect()
            }
        }
        // **FIX**: Listen for new events
        .onReceive(NotificationCenter.default.publisher(for: .newEventReceived)) { _ in
            // Trigger UI update
            objectWillChange.send()
        }
    }
    
    private func markAsRead(_ alert: Event) {
        guard let channelName = alert.channelName else { return }
        subscriptionManager.markAsRead(channelId: channelName)
    }
    
    private func markAllAsRead() {
        for channel in subscriptionManager.subscribedChannels {
            subscriptionManager.markAsRead(channelId: channel.id)
        }
    }
}

enum AlertFilter {
    case all
    case unread
    case important
}

struct AlertRowView: View {
    let alert: Event
    let onTap: () -> Void
    
    // **FIX**: Check unread status properly
    private var isUnread: Bool {
        guard let channelName = alert.channelName else { return false }
        return SubscriptionManager.shared.getUnreadCount(channelId: channelName) > 0
    }
    
    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                // Priority Indicator
                Circle()
                    .fill(priorityColor)
                    .frame(width: 12, height: 12)
                    .padding(.top, 4)
                
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(alert.title)
                            .font(.headline)
                            .foregroundColor(.primary)
                        Spacer()
                        if isUnread {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 8, height: 8)
                        }
                    }
                    
                    Text(alert.message)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    
                    HStack {
                        if let channelName = alert.channelName {
                            Text(channelName.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.1))
                                .foregroundColor(.blue)
                                .cornerRadius(4)
                        }
                        
                        Spacer()
                        
                        Text(timeAgo(from: alert.date))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private var priorityColor: Color {
        switch alert.priority?.lowercased() {
        case "high":
            return .red
        case "medium":
            return .orange
        default:
            return .green
        }
    }
    
    private func timeAgo(from date: Date) -> String {
        let now = Date()
        let interval = now.timeIntervalSince(date)
        
        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        }
    }
}
import SwiftUI

struct AlertsView: View {
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var webSocketService = WebSocketService.shared
    @State private var selectedFilter: AlertFilter = .all
    @State private var refreshTrigger = UUID() // ✅ Force refresh mechanism
    
    // ✅ CRITICAL: Direct observation of subscription manager changes
    private var allEvents: [Event] {
        var events: [Event] = []
        for channel in subscriptionManager.subscribedChannels {
            let channelEvents = subscriptionManager.getEvents(channelId: channel.id)
            events.append(contentsOf: channelEvents)
        }
        return events.sorted { $0.timestamp > $1.timestamp }
    }
    
    var filteredAlerts: [Event] {
        switch selectedFilter {
        case .all:
            return allEvents
        case .unread:
            return allEvents.filter { !$0.isRead }
        case .important:
            return allEvents.filter { $0.priority == "high" }
        }
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Filter Picker
                Picker("Filter", selection: $selectedFilter) {
                    Text("All").tag(AlertFilter.all)
                    Text("Unread").tag(AlertFilter.unread)
                    Text("Important").tag(AlertFilter.important)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding()
                
                // Connection Status
                connectionStatusBanner
                
                // Alerts List
                if filteredAlerts.isEmpty {
                    emptyStateView
                } else {
                    alertsList
                }
            }
            .navigationTitle("Alerts")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: markAllAsRead) {
                        Text("Mark All Read")
                            .font(.subheadline)
                    }
                    .disabled(filteredAlerts.filter { !$0.isRead }.isEmpty)
                }
            }
        }
        .onAppear {
            print("📱 AlertsView: Appeared")
            connectIfNeeded()
            setupNotificationObserver()
        }
        .onDisappear {
            print("📱 AlertsView: Disappeared")
            removeNotificationObserver()
        }
        // ✅ CRITICAL: Force refresh when subscription manager updates
        .id(refreshTrigger)
    }
    
    // MARK: - Connection Status Banner
    
    private var connectionStatusBanner: some View {
        Group {
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
        }
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
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
            
            if !subscriptionManager.subscribedChannels.isEmpty {
                Button("Refresh") {
                    forceRefresh()
                }
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Alerts List
    
    private var alertsList: some View {
        List {
            ForEach(filteredAlerts) { alert in
                AlertRowView(alert: alert) {
                    markAsRead(alert)
                }
            }
        }
    }
    
    // MARK: - Event Handling
    
    private func setupNotificationObserver() {
        NotificationCenter.default.addObserver(
            forName: .newEventReceived,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            print("📱 AlertsView: ⚡️⚡️⚡️ NOTIFICATION RECEIVED IN OBSERVER!")
            self?.handleNewEvent(notification)
        }
        
        print("📱 AlertsView: ✅ Notification observer setup complete")
        print("📱 AlertsView: Current subscribed channels: \(subscriptionManager.subscribedChannels.count)")
        print("📱 AlertsView: Current total events: \(allEvents.count)")
    }
    
    private func removeNotificationObserver() {
        NotificationCenter.default.removeObserver(self, name: .newEventReceived, object: nil)
        print("📱 AlertsView: Notification observer removed")
    }
    
    private func handleNewEvent(_ notification: Notification) {
        print("📱 AlertsView: ⚡️ NEW EVENT NOTIFICATION RECEIVED!")
        
        if let userInfo = notification.userInfo,
           let event = userInfo["event"] as? Event,
           let channelId = userInfo["channelId"] as? String {
            print("📱 AlertsView: New event: \(event.title) in channel \(channelId)")
            print("📱 AlertsView: Current event count: \(allEvents.count)")
        }
        
        // ✅ CRITICAL: Force complete UI refresh
        withAnimation(.easeInOut(duration: 0.3)) {
            refreshTrigger = UUID()
        }
        
        // Also trigger a secondary refresh after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            refreshTrigger = UUID()
        }
        
        print("📱 AlertsView: ✅ UI refresh triggered")
    }
    
    private func connectIfNeeded() {
        if !webSocketService.isConnected {
            print("📱 AlertsView: Connecting WebSocket...")
            webSocketService.connect()
        } else {
            print("📱 AlertsView: Already connected")
        }
    }
    
    private func forceRefresh() {
        print("📱 AlertsView: Manual refresh triggered")
        refreshTrigger = UUID()
        
        // Also log current state
        print("📱 AlertsView: Subscribed channels: \(subscriptionManager.subscribedChannels.count)")
        print("📱 AlertsView: Total events: \(allEvents.count)")
        
        for channel in subscriptionManager.subscribedChannels {
            let events = subscriptionManager.getEvents(channelId: channel.id)
            print("📱 AlertsView: Channel \(channel.id) has \(events.count) events")
        }
    }
    
    private func markAsRead(_ alert: Event) {
        guard let channelId = alert.channelName else { return }
        subscriptionManager.markAsRead(channelId: channelId)
        
        // Force refresh
        withAnimation {
            refreshTrigger = UUID()
        }
    }
    
    private func markAllAsRead() {
        for channel in subscriptionManager.subscribedChannels {
            subscriptionManager.markAsRead(channelId: channel.id)
        }
        
        // Force refresh
        withAnimation {
            refreshTrigger = UUID()
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
                        if !alert.isRead {
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
                        Text(alert.channelName ?? "General")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.1))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                        
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

// MARK: - Preview Provider

struct AlertsView_Previews: PreviewProvider {
    static var previews: some View {
        AlertsView()
    }
}
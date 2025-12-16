import SwiftUI

struct AlertsView: View {
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var webSocketService = WebSocketService.shared
    @State private var selectedFilter: AlertFilter = .all
    @State private var refreshID = UUID() // ✅ Force refresh trigger
    
    // ✅ FIXED: Listen to real-time event updates
    private let eventPublisher = NotificationCenter.default
        .publisher(for: .newEventReceived)
    
    var filteredAlerts: [Event] {
        // Get all events from subscribed channels
        var allEvents: [Event] = []
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
            setupEventListeners()
            connectIfNeeded()
        }
        .onDisappear {
            removeEventListeners()
        }
        // ✅ CRITICAL: Listen to real-time events
        .onReceive(eventPublisher) { notification in
            handleNewEvent(notification)
        }
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
                .id("\(alert.id ?? "")-\(refreshID)") // ✅ Force refresh with unique ID
            }
        }
        .id(refreshID) // ✅ Force list refresh
    }
    
    // MARK: - Event Handling
    
    private func setupEventListeners() {
        // Already handled by .onReceive
        print("📱 AlertsView: Event listeners active")
    }
    
    private func removeEventListeners() {
        // Handled automatically by .onReceive
        print("📱 AlertsView: Event listeners removed")
    }
    
    private func handleNewEvent(_ notification: Notification) {
        print("📱 AlertsView: Received new event notification")
        
        // ✅ Force UI refresh with animation
        withAnimation(.easeInOut(duration: 0.3)) {
            refreshID = UUID()
        }
        
        // Optional: Show toast or banner for new event
        if let userInfo = notification.userInfo,
           let event = userInfo["event"] as? Event {
            print("📱 New event: \(event.title) at \(event.location)")
        }
    }
    
    private func connectIfNeeded() {
        if !webSocketService.isConnected {
            print("📱 AlertsView: Connecting WebSocket...")
            webSocketService.connect()
        } else {
            print("📱 AlertsView: Already connected")
        }
    }
    
    private func markAsRead(_ alert: Event) {
        guard let channelId = alert.channelName else { return }
        subscriptionManager.markAsRead(channelId: channelId)
        
        // ✅ Force refresh
        withAnimation {
            refreshID = UUID()
        }
    }
    
    private func markAllAsRead() {
        for channel in subscriptionManager.subscribedChannels {
            subscriptionManager.markAsRead(channelId: channel.id)
        }
        
        // ✅ Force refresh
        withAnimation {
            refreshID = UUID()
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
import SwiftUI

struct ChannelDetailView: View {
    let channel: Channel
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var webSocketService = WebSocketService.shared
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var pendingEventsCount = 0
    @State private var showNewEventsBanner = false
    @State private var selectedEvent: Event? = nil
    @State private var showingImageDetail = false
    
    @Environment(\.presentationMode) var presentationMode
    
    var isSubscribed: Bool {
        subscriptionManager.isSubscribed(channelId: channel.id)
    }
    
    var isMuted: Bool {
        subscriptionManager.isChannelMuted(channelId: channel.id)
    }
    
    var events: [Event] {
        subscriptionManager.getEvents(channelId: channel.id)
    }
    
    var unreadCount: Int {
        subscriptionManager.getUnreadCount(channelId: channel.id)
    }
    
    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Channel Header
                    channelHeader
                    
                    Divider()
                    
                    // Subscription Controls
                    subscriptionSection
                    
                    Divider()
                    
                    // Events Section
                    if isSubscribed {
                        eventsSection
                    }
                }
                .padding()
            }
            
            // New Events Banner
            if showNewEventsBanner && pendingEventsCount > 0 {
                VStack {
                    HStack {
                        Image(systemName: "bell.badge.fill")
                        Text("\(pendingEventsCount) new event\(pendingEventsCount == 1 ? "" : "s")")
                            .font(.subheadline)
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Button("View") {
                            showNewEventsBanner = false
                            pendingEventsCount = 0
                        }
                        .font(.subheadline)
                        .font(.system(size: 14, weight: .semibold))
                    }
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                    .padding()
                    .shadow(radius: 5)
                    
                    Spacer()
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .alert(isPresented: $showingAlert) {
            Alert(
                title: Text("Subscription"),
                message: Text(alertMessage),
                dismissButton: .default(Text("OK"))
            )
        }
        .fullScreenCover(item: $selectedEvent) { event in
            ImageDetailView(event: event)
        }
        .onAppear {
            markAsRead()
            subscribeToNotifications()
        }
        .onDisappear {
            unsubscribeFromNotifications()
        }
    }
    
    // MARK: - Views
    
    private var channelHeader: some View {
        HStack(alignment: .top) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.2))
                    .frame(width: 80, height: 80)
                
                Text(iconText)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(iconColor)
            }
            
            Spacer()
        }
        .padding(.top)
    }
    
    private var subscriptionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Channel Details")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Area")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(channel.areaDisplay)
                        .font(.system(size: 17, weight: .semibold))
                }
                
                HStack {
                    Text("Type")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(channel.eventTypeDisplay)
                        .font(.system(size: 17, weight: .semibold))
                }
                
                if isSubscribed {
                    HStack {
                        Text("Status")
                            .foregroundColor(.secondary)
                        Spacer()
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                            Text("Subscribed")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.green)
                        }
                    }
                }
            }
            
            Divider()
            
            // Subscription Toggle
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isSubscribed ? "Subscribed to alerts" : "Subscribe to alerts")
                        .font(.body)
                    Text("Receive notifications for new events")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: toggleSubscription) {
                    Text(isSubscribed ? "Unsubscribe" : "Subscribe")
                        .font(.subheadline)
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(isSubscribed ? Color.red.opacity(0.1) : Color.blue)
                        .foregroundColor(isSubscribed ? .red : .white)
                        .cornerRadius(8)
                }
            }
            
            // Mute Toggle (only if subscribed)
            if isSubscribed {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mute notifications")
                            .font(.body)
                        Text("Stop receiving push notifications")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: Binding(
                        get: { isMuted },
                        set: { _ in toggleMute() }
                    ))
                    .labelsHidden()
                }
            }
        }
    }
    
    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Recent Events")
                    .font(.headline)
                
                Spacer()
                
                Text("\(events.count) events")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            if events.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 40))
                        .foregroundColor(.gray)
                    Text("No events yet")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("New events will appear here")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                ForEach(events) { event in
                    EventRowView(event: event) {
                        // ✅ FIX: Open image detail view
                        selectedEvent = event
                        showingImageDetail = true
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }
    
    // MARK: - Computed Properties
    
    private var iconText: String {
        let type = channel.eventType.uppercased()
        if type.count <= 2 {
            return type
        }
        return String(type.prefix(2))
    }
    
    private var iconColor: Color {
        switch channel.eventType.lowercased() {
        case "cd": return Color(hex: "FF5722")
        case "id": return Color(hex: "F44336")
        case "ct": return Color(hex: "E91E63")
        case "sh": return Color(hex: "FF9800")
        case "vd": return Color(hex: "2196F3")
        case "pd": return Color(hex: "4CAF50")
        case "vc": return Color(hex: "FFC107")
        case "ii": return Color(hex: "9C27B0")
        case "ls": return Color(hex: "00BCD4")
        case "off-route": return Color(hex: "FF5722")
        case "tamper": return Color(hex: "F44336")
        default: return Color(hex: "9E9E9E")
        }
    }
    
    // MARK: - Actions
    
    private func toggleSubscription() {
        if isSubscribed {
            subscriptionManager.unsubscribe(channelId: channel.id)
            alertMessage = "Unsubscribed from \(channel.areaDisplay)"
        } else {
            subscriptionManager.subscribe(channel: channel)
            alertMessage = "Subscribed to \(channel.areaDisplay)"
        }
        showingAlert = true
    }
    
    private func toggleMute() {
        var updatedChannel = channel
        updatedChannel.isMuted = !isMuted
        subscriptionManager.updateChannel(updatedChannel)
        
        alertMessage = isMuted ? "Notifications enabled" : "Notifications muted"
        showingAlert = true
    }
    
    private func markAsRead() {
        if unreadCount > 0 {
            subscriptionManager.markAsRead(channelId: channel.id)
        }
    }
    
    // MARK: - Event Notifications
    
    private func subscribeToNotifications() {
        NotificationCenter.default.addObserver(
            forName: .newEventReceived,
            object: nil,
            queue: .main
        ) { notification in
            if let userInfo = notification.userInfo,
               let channelId = userInfo["channelId"] as? String,
               channelId == channel.id {
                pendingEventsCount += 1
                showNewEventsBanner = true
                
                // Auto-hide banner after 5 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    showNewEventsBanner = false
                }
            }
        }
    }
    
    private func unsubscribeFromNotifications() {
        NotificationCenter.default.removeObserver(self, name: .newEventReceived, object: nil)
    }
}

// ✅ UPDATED: EventRowView with tap action
struct EventRowView: View {
    let event: Event
    let onTap: () -> Void
    
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM dd, yyyy HH:mm"
        return formatter
    }()
    
    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                // Event indicator
                Circle()
                    .fill(Color.blue)
                    .frame(width: 10, height: 10)
                    .padding(.top, 4)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.typeDisplay ?? event.type ?? "Event")
                        .font(.subheadline)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary)
                    
                    Text(event.location)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text(dateFormatter.string(from: event.date))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // ✅ NEW: Indicate tappable
                Image(systemName: "photo")
                    .foregroundColor(.blue)
                    .font(.system(size: 20))
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(8)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// ✅ Make Event identifiable for fullScreenCover
extension Event: Identifiable {}
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
    @State private var refreshTrigger = UUID()
    
    @State private var eventObserver: NSObjectProtocol?
    
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
            // ✅ FIXED: Show events list immediately if subscribed
            if isSubscribed {
                eventsListView
            } else {
                subscriptionPromptView
            }
            
            // New Events Banner
            if showNewEventsBanner && pendingEventsCount > 0 {
                newEventsBanner
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(channel.areaDisplay)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    // Mute/Unmute button
                    if isSubscribed {
                        Button(action: toggleMute) {
                            Image(systemName: isMuted ? "bell.slash.fill" : "bell.fill")
                                .foregroundColor(isMuted ? .orange : .blue)
                        }
                    }
                    
                    // Subscribe/Unsubscribe button
                    Button(action: toggleSubscription) {
                        Text(isSubscribed ? "Unsubscribe" : "Subscribe")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(isSubscribed ? .red : .blue)
                    }
                }
            }
        }
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
            setupNotificationObserver()
        }
        .onDisappear {
            removeNotificationObserver()
        }
        .id(refreshTrigger)
    }
    
    // MARK: - Events List View (Telegram Style)
    
    private var eventsListView: some View {
        VStack(spacing: 0) {
            // Channel Info Header
            channelInfoHeader
            
            Divider()
            
            // Events List
            if events.isEmpty {
                emptyEventsView
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(events) { event in
                            EventMessageRow(event: event, channel: channel) {
                                selectedEvent = event
                                showingImageDetail = true
                            }
                            
                            Divider()
                                .padding(.leading, 80)
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Channel Info Header
    
    private var channelInfoHeader: some View {
        HStack(spacing: 12) {
            // Channel Icon
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.2))
                    .frame(width: 50, height: 50)
                
                Text(iconText)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(iconColor)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(channel.areaDisplay)
                    .font(.headline)
                
                Text(channel.eventTypeDisplay)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(isSubscribed ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(isSubscribed ? "Subscribed" : "Not subscribed")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    if events.count > 0 {
                        Text("•")
                            .foregroundColor(.secondary)
                        Text("\(events.count) events")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
        }
        .padding()
        .background(Color(.systemBackground))
    }
    
    // MARK: - Empty Events View
    
    private var emptyEventsView: some View {
        VStack(spacing: 16) {
            Spacer()
            
            Image(systemName: "tray")
                .font(.system(size: 50))
                .foregroundColor(.gray)
            
            Text("No events yet")
                .font(.headline)
                .foregroundColor(.primary)
            
            Text("New events will appear here automatically")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Subscription Prompt View
    
    private var subscriptionPromptView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.2))
                    .frame(width: 100, height: 100)
                
                Text(iconText)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundColor(iconColor)
            }
            
            VStack(spacing: 8) {
                Text(channel.areaDisplay)
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text(channel.eventTypeDisplay)
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
            
            Text("Subscribe to receive alerts for this channel")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Button(action: toggleSubscription) {
                HStack {
                    Image(systemName: "bell.badge.fill")
                    Text("Subscribe to Channel")
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 30)
                .padding(.vertical, 15)
                .background(Color.blue)
                .cornerRadius(12)
            }
            .padding(.top, 20)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - New Events Banner
    
    private var newEventsBanner: some View {
        VStack {
            HStack {
                Image(systemName: "bell.badge.fill")
                Text("\(pendingEventsCount) new event\(pendingEventsCount == 1 ? "" : "s")")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("View") {
                    showNewEventsBanner = false
                    pendingEventsCount = 0
                    refreshTrigger = UUID()
                }
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
        let wasSubscribed = isSubscribed
        let channelToSubscribe = channel
        
        alertMessage = wasSubscribed ? "Unsubscribing..." : "Subscribing..."
        showingAlert = true
        
        if wasSubscribed {
            subscriptionManager.unsubscribe(channelId: channelToSubscribe.id)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                alertMessage = "Unsubscribed from \(channelToSubscribe.areaDisplay)"
                showingAlert = true
                refreshTrigger = UUID()
            }
        } else {
            subscriptionManager.subscribe(channel: channelToSubscribe)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                alertMessage = "Subscribed to \(channelToSubscribe.areaDisplay)"
                showingAlert = true
                refreshTrigger = UUID()
            }
        }
    }
    
    private func toggleMute() {
        var updatedChannel = channel
        updatedChannel.isMuted = !isMuted
        subscriptionManager.updateChannel(updatedChannel)
        
        alertMessage = isMuted ? "Notifications enabled" : "Notifications muted"
        showingAlert = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            refreshTrigger = UUID()
        }
    }
    
    private func markAsRead() {
        if unreadCount > 0 {
            subscriptionManager.markAsRead(channelId: channel.id)
        }
    }
    
    // MARK: - Event Notifications
    
    private func setupNotificationObserver() {
        removeNotificationObserver()
        
        let channelId = channel.id
        
        eventObserver = NotificationCenter.default.addObserver(
            forName: .newEventReceived,
            object: nil,
            queue: OperationQueue()
        ) { notification in
            guard let userInfo = notification.userInfo,
                  let eventChannelId = userInfo["channelId"] as? String,
                  eventChannelId == channelId else {
                return
            }
            
            DispatchQueue.main.async {
                self.pendingEventsCount += 1
                self.showNewEventsBanner = true
                self.refreshTrigger = UUID()
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    self.showNewEventsBanner = false
                }
            }
        }
    }
    
    private func removeNotificationObserver() {
        if let observer = eventObserver {
            NotificationCenter.default.removeObserver(observer)
            eventObserver = nil
        }
    }
}

// MARK: - Event Message Row (Telegram Style)

struct EventMessageRow: View {
    let event: Event
    let channel: Channel
    let onTap: () -> Void
    
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    
    private let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM dd, yyyy"
        return formatter
    }()
    
    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                // Event Type Icon
                ZStack {
                    Circle()
                        .fill(eventColor.opacity(0.2))
                        .frame(width: 40, height: 40)
                    
                    Text(eventIconText)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(eventColor)
                }
                .padding(.top, 4)
                
                VStack(alignment: .leading, spacing: 8) {
                    // Event Header
                    HStack {
                        Text(event.typeDisplay ?? event.type ?? "Event")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary)
                        
                        Spacer()
                        
                        Text(dateFormatter.string(from: event.date))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    // Event Location
                    Text(event.location)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    
                    // Event Image (using CachedEventImage helper)
                    CachedEventImage(event: event)
                        .frame(height: 200)
                        .clipped()
                        .cornerRadius(12)
                    
                    // Event Date
                    Text(fullDateFormatter.string(from: event.date))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private var eventIconText: String {
        let type = (event.type ?? "").uppercased()
        if type.count <= 2 {
            return type
        }
        return String(type.prefix(2))
    }
    
    private var eventColor: Color {
        switch (event.type ?? "").lowercased() {
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
}
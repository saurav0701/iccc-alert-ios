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
            if isSubscribed {
                eventsListView
            } else {
                subscriptionPromptView
            }

            if showNewEventsBanner && pendingEventsCount > 0 {
                newEventsBanner
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(channel.eventTypeDisplay)
                        .font(.headline)
                    
                    HStack(spacing: 8) {
                        if let area = headerAreaText {
                            Text(area)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        if isSubscribed && events.count > 0 {
                            Text("•")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text("\(events.count) events")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    if isSubscribed {
                        Button(action: toggleMute) {
                            Image(systemName: isMuted ? "bell.slash.fill" : "bell.fill")
                                .foregroundColor(isMuted ? .orange : .blue)
                        }
                    }

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
            print("📱 ChannelDetailView appeared - marking as read")
            markAsRead()
            setupNotificationObserver()
        }
        .onDisappear {
            print("📱 ChannelDetailView disappeared")
            removeNotificationObserver()
        }
        .id(refreshTrigger)
    }
    
    private var headerAreaText: String? {
        let latestEvent = events.first
        return latestEvent?.areaDisplay ?? latestEvent?.area
    }
    
    private var eventsListView: some View {
        VStack(spacing: 0) {
            if events.isEmpty {
                emptyEventsView
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(events) { event in
                            ModernEventCard(
                                event: event,
                                channel: channel,
                                onTap: {
                                    selectedEvent = event
                                    showingImageDetail = true
                                },
                                onSaveToggle: {
                                    toggleSaveEvent(event)
                                }
                            )
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 12)
                }
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    private var emptyEventsView: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.blue.opacity(0.1), Color.purple.opacity(0.1)]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)
                
                Image(systemName: "tray")
                    .font(.system(size: 40))
                    .foregroundColor(.blue)
            }
            
            Text("No Events Yet")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("New events will appear here automatically when they occur")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private var subscriptionPromptView: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [iconColor.opacity(0.2), iconColor.opacity(0.1)]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 120, height: 120)
                    .shadow(color: iconColor.opacity(0.2), radius: 20, x: 0, y: 10)
                
                Text(iconText)
                    .font(.system(size: 48, weight: .bold))
                    .foregroundColor(iconColor)
            }
            
            VStack(spacing: 8) {
                Text(channel.eventTypeDisplay)
                    .font(.title)
                    .fontWeight(.bold)
                
                Text(channel.areaDisplay)
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            
            Text("Get real-time alerts for this channel")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button(action: toggleSubscription) {
                HStack(spacing: 12) {
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 18))
                    Text("Subscribe to Channel")
                        .font(.headline)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    LinearGradient(
                        gradient: Gradient(colors: [iconColor, iconColor.opacity(0.8)]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .cornerRadius(14)
                .shadow(color: iconColor.opacity(0.3), radius: 10, x: 0, y: 5)
            }
            .padding(.horizontal, 40)
            .padding(.top, 8)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private var newEventsBanner: some View {
        VStack {
            HStack(spacing: 12) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 16))
                
                Text("\(pendingEventsCount) new event\(pendingEventsCount == 1 ? "" : "s")")
                    .font(.system(size: 15, weight: .semibold))
                
                Spacer()
                
                Button("View") {
                    withAnimation(.spring()) {
                        showNewEventsBanner = false
                        pendingEventsCount = 0
                        refreshTrigger = UUID()
                    }
                }
                .font(.system(size: 15, weight: .semibold))
            }
            .padding()
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [Color.blue, Color.blue.opacity(0.9)]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .foregroundColor(.white)
            .cornerRadius(14)
            .shadow(color: Color.blue.opacity(0.3), radius: 10, x: 0, y: 5)
            .padding()
            
            Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

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

    private func toggleSubscription() {
        let wasSubscribed = isSubscribed
        let channelToSubscribe = channel
        
        withAnimation(.spring()) {
            alertMessage = wasSubscribed ? "Unsubscribing..." : "Subscribing..."
            showingAlert = true
        }
        
        if wasSubscribed {
            subscriptionManager.unsubscribe(channelId: channelToSubscribe.id)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                alertMessage = "Unsubscribed from \(channelToSubscribe.eventTypeDisplay)"
                showingAlert = true
                refreshTrigger = UUID()
            }
        } else {
            subscriptionManager.subscribe(channel: channelToSubscribe)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                alertMessage = "Subscribed to \(channelToSubscribe.eventTypeDisplay)"
                showingAlert = true
                refreshTrigger = UUID()
            }
        }
    }
    
    private func toggleMute() {
        var updatedChannel = channel
        updatedChannel.isMuted = !isMuted
        subscriptionManager.updateChannel(updatedChannel)
        
        withAnimation(.spring()) {
            alertMessage = isMuted ? "Notifications enabled" : "Notifications muted"
            showingAlert = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            refreshTrigger = UUID()
        }
    }
    
    private func toggleSaveEvent(_ event: Event) {
        subscriptionManager.toggleSaveEvent(channelId: channel.id, eventId: event.id ?? "")
        
        DispatchQueue.main.async {
            refreshTrigger = UUID()
        }
    }
    
    private func markAsRead() {
        if unreadCount > 0 {
            print("✅ Marking \(unreadCount) events as read for channel: \(channel.id)")
            subscriptionManager.markAsRead(channelId: channel.id)
            
            // Force refresh after marking as read
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                refreshTrigger = UUID()
            }
        }
    }
 
    private func setupNotificationObserver() {
        removeNotificationObserver()
        
        let channelId = channel.id
        
        eventObserver = NotificationCenter.default.addObserver(
            forName: .newEventReceived,
            object: nil,
            queue: OperationQueue.main
        ) { notification in
            guard let userInfo = notification.userInfo,
                  let eventChannelId = userInfo["channelId"] as? String,
                  eventChannelId == channelId else {
                return
            }
            
            DispatchQueue.main.async {
                withAnimation(.spring()) {
                    self.pendingEventsCount += 1
                    self.showNewEventsBanner = true
                    self.refreshTrigger = UUID()
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    withAnimation(.spring()) {
                        self.showNewEventsBanner = false
                    }
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

struct ModernEventCard: View {
    let event: Event
    let channel: Channel
    let onTap: () -> Void
    let onSaveToggle: () -> Void
    
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(eventColor)
                        .frame(width: 8, height: 8)
                    
                    Text(event.typeDisplay ?? event.type ?? "Event")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(eventColor)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(eventColor.opacity(0.15))
                .cornerRadius(8)
                
                Spacer()
                
                // Save/Bookmark Button
                Button(action: onSaveToggle) {
                    Image(systemName: event.isSaved ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 18))
                        .foregroundColor(event.isSaved ? .yellow : .gray)
                }
                .padding(.trailing, 8)
                
                Text(dateFormatter.string(from: event.date))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
            }

            Text(event.location)
                .font(.body)
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .lineLimit(2)

            Button(action: onTap) {
                CachedEventImage(event: event)
                    .frame(height: 200)
                    .clipped()
                    .cornerRadius(12)
                    .shadow(color: Color.black.opacity(0.1), radius: 5, x: 0, y: 2)
            }
            .buttonStyle(PlainButtonStyle())

            Text(fullDateFormatter.string(from: event.date))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 5)
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
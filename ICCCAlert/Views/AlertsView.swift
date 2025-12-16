import SwiftUI

struct AlertsView: View {
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var webSocketService = WebSocketService.shared
    @State private var selectedFilter: AlertFilter = .all
    @State private var refreshTrigger = UUID()
    @State private var isInitialLoad = true
    
    // Group events by channel
    private var channelGroups: [(channel: Channel, events: [Event])] {
        var groups: [(Channel, [Event])] = []
        
        for channel in subscriptionManager.subscribedChannels {
            let channelEvents = subscriptionManager.getEvents(channelId: channel.id)
            
            // Apply filters
            let filtered = filterEvents(channelEvents)
            
            if !filtered.isEmpty {
                groups.append((channel, filtered))
            }
        }
        
        // Sort by most recent event
        return groups.sorted(by: { group1, group2 in
            let time1 = group1.events.first?.timestamp ?? 0
            let time2 = group2.events.first?.timestamp ?? 0
            return time1 > time2
        })
    }
    
    private var hasSubscriptions: Bool {
        !subscriptionManager.subscribedChannels.isEmpty
    }
    
    private var totalEventCount: Int {
        subscriptionManager.getTotalEventCount()
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Filter Picker
                if totalEventCount > 0 {
                    Picker("Filter", selection: $selectedFilter) {
                        Text("All").tag(AlertFilter.all)
                        Text("Unread").tag(AlertFilter.unread)
                        Text("Important").tag(AlertFilter.important)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .padding()
                }
                
                // Connection Status
                connectionStatusBanner
                
                // Content
                contentView
            }
            .navigationTitle("Alerts")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !hasNoUnread {
                        Button(action: markAllAsRead) {
                            Text("Mark All Read")
                                .font(.subheadline)
                        }
                    }
                }
            }
        }
        .onAppear {
            print("📱 AlertsView: Appeared")
            handleViewAppear()
        }
        .onDisappear {
            print("📱 AlertsView: Disappeared")
            removeNotificationObserver()
        }
        .id(refreshTrigger)
    }
    
    // MARK: - Content View
    
    @ViewBuilder
    private var contentView: some View {
        if isInitialLoad && !webSocketService.isConnected {
            loadingView
        } else if !hasSubscriptions {
            noSubscriptionsView
        } else if channelGroups.isEmpty && totalEventCount == 0 {
            waitingForEventsView
        } else if channelGroups.isEmpty {
            noFilteredEventsView
        } else {
            channelsList
        }
    }
    
    // MARK: - Loading View
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Connecting...")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    Text("Connected")
                        .font(.caption)
                        .foregroundColor(.green)
                    Spacer()
                    if totalEventCount > 0 {
                        Text("\(totalEventCount) events")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Waiting for events...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.1))
            }
        }
    }
    
    // MARK: - No Subscriptions View
    
    private var noSubscriptionsView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bell.slash")
                .font(.system(size: 50))
                .foregroundColor(.gray)
            Text("No Subscriptions")
                .font(.headline)
            Text("Subscribe to channels to receive alerts")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Waiting for Events View
    
    private var waitingForEventsView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
                .padding(.bottom, 8)
            
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 40))
                .foregroundColor(.blue)
            
            Text("Waiting for Events")
                .font(.headline)
            
            Text("Subscribed to \(subscriptionManager.subscribedChannels.count) channel\(subscriptionManager.subscribedChannels.count == 1 ? "" : "s")")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Text("New events will appear here automatically")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Subscribed Channels:")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                
                ForEach(subscriptionManager.subscribedChannels.prefix(5)) { channel in
                    HStack {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 6, height: 6)
                        Text("\(channel.areaDisplay) - \(channel.eventTypeDisplay)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                if subscriptionManager.subscribedChannels.count > 5 {
                    Text("+ \(subscriptionManager.subscribedChannels.count - 5) more")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 14)
                }
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(8)
            .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - No Filtered Events View
    
    private var noFilteredEventsView: some View {
        VStack(spacing: 16) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 50))
                .foregroundColor(.gray)
            Text("No Events Match Filter")
                .font(.headline)
            Text("Try changing your filter to see more events")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button("Show All") {
                selectedFilter = .all
            }
            .padding()
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Channels List
    
    private var channelsList: some View {
        List {
            ForEach(channelGroups, id: \.channel.id) { group in
                NavigationLink(
                    destination: ChannelEventsView(channel: group.channel, events: group.events)
                ) {
                    AlertChannelRow(
                        channel: group.channel,
                        lastEvent: group.events.first,
                        unreadCount: subscriptionManager.getUnreadCount(channelId: group.channel.id)
                    )
                }
            }
        }
    }
    
    // MARK: - Filter Logic
    
    private func filterEvents(_ events: [Event]) -> [Event] {
        switch selectedFilter {
        case .all:
            return events
        case .unread:
            return events.filter { !$0.isRead }
        case .important:
            return events.filter { $0.priority?.lowercased() == "high" }
        }
    }
    
    // MARK: - Computed Properties
    
    private var hasNoUnread: Bool {
        channelGroups.allSatisfy { group in
            subscriptionManager.getUnreadCount(channelId: group.channel.id) == 0
        }
    }
    
    // MARK: - Event Handling
    
    private func handleViewAppear() {
        connectIfNeeded()
        setupNotificationObserver()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            isInitialLoad = false
        }
    }
    
    private func setupNotificationObserver() {
        NotificationCenter.default.addObserver(
            forName: .newEventReceived,
            object: nil,
            queue: .main
        ) { [self] notification in
            self.handleNewEvent(notification)
        }
        
        print("📱 AlertsView: Notification observer setup complete")
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
            print("📱 AlertsView: Current total events: \(totalEventCount)")
        }
        
        // Simple refresh without animation to prevent UI freeze
        refreshTrigger = UUID()
        
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
    
    private func markAllAsRead() {
        for channel in subscriptionManager.subscribedChannels {
            subscriptionManager.markAsRead(channelId: channel.id)
        }
        
        refreshTrigger = UUID()
    }
}

// MARK: - Alert Channel Row (renamed to avoid conflict)

struct AlertChannelRow: View {
    let channel: Channel
    let lastEvent: Event?
    let unreadCount: Int
    
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Channel Icon
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.2))
                    .frame(width: 50, height: 50)
                
                Text(iconText)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(iconColor)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if unreadCount > 0 {
                        Text("\(channel.areaDisplay)")
                            .font(.headline)
                            .fontWeight(.bold)
                    } else {
                        Text("\(channel.areaDisplay)")
                            .font(.headline)
                    }
                    
                    Spacer()
                    
                    if let event = lastEvent {
                        Text(dateFormatter.string(from: event.date))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                if let event = lastEvent {
                    if unreadCount > 0 {
                        Text(event.message)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .fontWeight(.semibold)
                    } else {
                        Text(event.message)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
                
                HStack {
                    Text(channel.eventTypeDisplay)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(iconColor.opacity(0.1))
                        .foregroundColor(iconColor)
                        .cornerRadius(4)
                    
                    Spacer()
                    
                    if unreadCount > 0 {
                        Text("\(unreadCount)")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 8)
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
}

// MARK: - Channel Events View

struct ChannelEventsView: View {
    let channel: Channel
    let events: [Event]
    
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @State private var refreshTrigger = UUID()
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(events) { event in
                    EventCardView(event: event)
                        .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(channel.areaDisplay)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            subscriptionManager.markAsRead(channelId: channel.id)
        }
        .id(refreshTrigger)
    }
}

// MARK: - Event Card View

struct EventCardView: View {
    let event: Event
    @State private var showFullImage = false
    
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM dd, yyyy HH:mm"
        return formatter
    }()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Event Header
            HStack {
                Text(event.title)
                    .font(.headline)
                
                Spacer()
                
                Circle()
                    .fill(priorityColor)
                    .frame(width: 8, height: 8)
            }
            
            // Event Image (if not GPS event)
            if event.type != "off-route" && event.type != "tamper" && event.type != "overspeed" {
                Button(action: { showFullImage = true }) {
                    AsyncImageView(event: event)
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                // GPS Event indicator
                HStack {
                    Image(systemName: "location.fill")
                        .foregroundColor(.orange)
                    Text("GPS Event - Tap to view on map")
                        .font(.subheadline)
                        .foregroundColor(.orange)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }
            
            // Event Details
            VStack(alignment: .leading, spacing: 8) {
                Text(event.message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                HStack {
                    Image(systemName: "location.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(event.location)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Text(dateFormatter.string(from: event.date))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .sheet(isPresented: $showFullImage) {
            FullImageView(event: event)
        }
    }
    
    private var priorityColor: Color {
        switch event.priority?.lowercased() {
        case "high":
            return .red
        case "medium":
            return .orange
        default:
            return .green
        }
    }
}

// MARK: - Full Image View

struct FullImageView: View {
    let event: Event
    @Environment(\.presentationMode) var presentationMode
    @StateObject private var imageLoader = ImageLoader()
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all)
                
                if let image = imageLoader.image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if imageLoader.isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                } else {
                    Text("Failed to load image")
                        .foregroundColor(.white)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button("Done") {
                presentationMode.wrappedValue.dismiss()
            })
        }
        .onAppear {
            imageLoader.loadImage(for: event)
        }
    }
}

enum AlertFilter {
    case all
    case unread
    case important
}
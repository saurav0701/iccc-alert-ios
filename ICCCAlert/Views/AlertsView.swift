import SwiftUI

struct AlertsView: View {
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var webSocketService = WebSocketService.shared
    @State private var selectedReadFilter: AlertFilter = .all
    @State private var selectedAreaFilter: String = "all"
    @State private var selectedEventTypeFilter: String = "all"
    @State private var isInitialLoad = true
    @State private var showFilterSheet = false
    
    @State private var eventObserver: NSObjectProtocol?
    @State private var channelGroups: [(channel: Channel, events: [Event])] = []
    
    private var hasSubscriptions: Bool {
        !subscriptionManager.subscribedChannels.isEmpty
    }
    
    private var totalEventCount: Int {
        subscriptionManager.getTotalEventCount()
    }
    
    // Get unique areas from subscribed channels
    private var availableAreas: [String] {
        let areas = Set(subscriptionManager.subscribedChannels.map { $0.areaDisplay })
        return ["all"] + Array(areas).sorted()
    }
    
    // Get unique event types from subscribed channels
    private var availableEventTypes: [String] {
        let types = Set(subscriptionManager.subscribedChannels.map { $0.eventTypeDisplay })
        return ["all"] + Array(types).sorted()
    }
    
    private var activeFilterCount: Int {
        var count = 0
        if selectedReadFilter != .all { count += 1 }
        if selectedAreaFilter != "all" { count += 1 }
        if selectedEventTypeFilter != "all" { count += 1 }
        return count
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Filter Button Bar
                if totalEventCount > 0 {
                    HStack(spacing: 12) {
                        // Read/Unread Filter
                        Picker("", selection: $selectedReadFilter) {
                            Text("All").tag(AlertFilter.all)
                            Text("Unread").tag(AlertFilter.unread)
                            Text("Important").tag(AlertFilter.important)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        
                        // Advanced Filters Button
                        Button(action: { showFilterSheet = true }) {
                            HStack(spacing: 4) {
                                Image(systemName: "line.3.horizontal.decrease.circle")
                                if activeFilterCount > 0 {
                                    Text("\(activeFilterCount)")
                                        .font(.caption2)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                        .frame(width: 16, height: 16)
                                        .background(Color.blue)
                                        .clipShape(Circle())
                                }
                            }
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.blue.opacity(0.1))
                            .foregroundColor(.blue)
                            .cornerRadius(8)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
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
            .sheet(isPresented: $showFilterSheet) {
                FilterSheetView(
                    selectedAreaFilter: $selectedAreaFilter,
                    selectedEventTypeFilter: $selectedEventTypeFilter,
                    availableAreas: availableAreas,
                    availableEventTypes: availableEventTypes
                )
            }
        }
        .onAppear {
            print("📱 AlertsView: Appeared")
            handleViewAppear()
        }
        .onDisappear {
            print("📱 AlertsView: Disappeared")
            removeNotificationObservers()
        }
        .onChange(of: selectedReadFilter) { _ in updateChannelGroups() }
        .onChange(of: selectedAreaFilter) { _ in updateChannelGroups() }
        .onChange(of: selectedEventTypeFilter) { _ in updateChannelGroups() }
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
            
            Button("Clear Filters") {
                selectedReadFilter = .all
                selectedAreaFilter = "all"
                selectedEventTypeFilter = "all"
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
                    destination: ChannelDetailView(channel: group.channel)
                ) {
                    ImprovedAlertChannelRow(
                        channel: group.channel,
                        lastEvent: group.events.first,
                        unreadCount: subscriptionManager.getUnreadCount(channelId: group.channel.id)
                    )
                }
            }
        }
        .listStyle(PlainListStyle())
    }
    
    // MARK: - Filter Logic
    
    private func filterEvents(_ events: [Event]) -> [Event] {
        var filtered = events
        
        // Apply read filter
        switch selectedReadFilter {
        case .all:
            break
        case .unread:
            filtered = filtered.filter { !$0.isRead }
        case .important:
            filtered = filtered.filter { $0.priority?.lowercased() == "high" }
        }
        
        return filtered
    }
    
    private func shouldIncludeChannel(_ channel: Channel) -> Bool {
        // Area filter
        if selectedAreaFilter != "all" && channel.areaDisplay != selectedAreaFilter {
            return false
        }
        
        // Event type filter
        if selectedEventTypeFilter != "all" && channel.eventTypeDisplay != selectedEventTypeFilter {
            return false
        }
        
        return true
    }
    
    private func updateChannelGroups() {
        var groups: [(Channel, [Event])] = []
        
        for channel in subscriptionManager.subscribedChannels {
            // Apply channel-level filters
            if !shouldIncludeChannel(channel) {
                continue
            }
            
            let channelEvents = subscriptionManager.getEvents(channelId: channel.id)
            let filtered = filterEvents(channelEvents)
            
            if !filtered.isEmpty {
                groups.append((channel, filtered))
            }
        }
        
        channelGroups = groups.sorted { group1, group2 in
            let time1 = group1.1.first?.timestamp ?? 0
            let time2 = group2.1.first?.timestamp ?? 0
            return time1 > time2
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
        updateChannelGroups()
        setupNotificationObservers()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            isInitialLoad = false
        }
    }
    
    private func setupNotificationObservers() {
        removeNotificationObservers()
        
        eventObserver = NotificationCenter.default.addObserver(
            forName: .newEventReceived,
            object: nil,
            queue: OperationQueue.main
        ) { [self] _ in
            self.updateChannelGroups()
        }
        
        print("📱 AlertsView: Notification observers setup complete")
    }
    
    private func removeNotificationObservers() {
        if let observer = eventObserver {
            NotificationCenter.default.removeObserver(observer)
            eventObserver = nil
        }
        
        print("📱 AlertsView: Notification observers removed")
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
        
        updateChannelGroups()
    }
}

// MARK: - Improved Alert Channel Row

struct ImprovedAlertChannelRow: View {
    let channel: Channel
    let lastEvent: Event?
    let unreadCount: Int
    
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = TimeZone.current // Use device timezone
        return formatter
    }()
    
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Channel Icon
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.2))
                    .frame(width: 44, height: 44)
                
                Text(iconText)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(iconColor)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                // Event Type (Main Title)
                HStack {
                    Text(channel.eventTypeDisplay)
                        .font(.system(size: 16, weight: unreadCount > 0 ? .bold : .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    // Timestamp
                    if let event = lastEvent {
                        Text(formatTime(event.date))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                // Area Display
                if let area = lastEvent?.areaDisplay ?? lastEvent?.area {
                    Text(area)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                // Last Event Message
                if let event = lastEvent {
                    Text(event.message)
                        .font(.system(size: 14, weight: unreadCount > 0 ? .medium : .regular))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            
            // Unread Badge (aligned to center)
            if unreadCount > 0 {
                Text("\(unreadCount)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .frame(minWidth: 20, minHeight: 20)
                    .padding(.horizontal, 6)
                    .background(Color.blue)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 8)
    }
    
    private func formatTime(_ date: Date) -> String {
        return dateFormatter.string(from: date)
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

// MARK: - Filter Sheet View

struct FilterSheetView: View {
    @Binding var selectedAreaFilter: String
    @Binding var selectedEventTypeFilter: String
    let availableAreas: [String]
    let availableEventTypes: [String]
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Filter by Area")) {
                    Picker("Area", selection: $selectedAreaFilter) {
                        ForEach(availableAreas, id: \.self) { area in
                            Text(area == "all" ? "All Areas" : area).tag(area)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                }
                
                Section(header: Text("Filter by Event Type")) {
                    Picker("Event Type", selection: $selectedEventTypeFilter) {
                        ForEach(availableEventTypes, id: \.self) { type in
                            Text(type == "all" ? "All Types" : type).tag(type)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                }
                
                Section {
                    Button("Clear All Filters") {
                        selectedAreaFilter = "all"
                        selectedEventTypeFilter = "all"
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationTitle("Advanced Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
}

enum AlertFilter {
    case all
    case unread
    case important
}
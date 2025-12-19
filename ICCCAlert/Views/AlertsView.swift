import SwiftUI

struct AlertsView: View {
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var webSocketService = WebSocketService.shared
    @State private var selectedReadFilter: AlertFilter = .all
    @State private var selectedAreas: Set<String> = []
    @State private var selectedEventTypes: Set<String> = []

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
    
    private var availableAreas: [String] {
        Array(Set(subscriptionManager.subscribedChannels.map { $0.area })).sorted()
    }

    private var availableEventTypes: [String] {
        Array(Set(subscriptionManager.subscribedChannels.map { $0.eventTypeDisplay })).sorted()
    }
    
    private var activeFilterCount: Int {
        var count = 0
        if selectedReadFilter != .all { count += 1 }
        if !selectedAreas.isEmpty { count += 1 }
        if !selectedEventTypes.isEmpty { count += 1 }
        return count
    }
    
    var body: some View {
        NavigationView {
            contentViewWrapper
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
                        selectedAreas: $selectedAreas,
                        selectedEventTypes: $selectedEventTypes,
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
        .onChange(of: selectedReadFilter) { _ in 
            print("🔄 Filter changed, updating groups")
            updateChannelGroups() 
        }
        .onChange(of: selectedAreas) { _ in 
            print("🔄 Areas changed, updating groups")
            updateChannelGroups() 
        }
        .onChange(of: selectedEventTypes) { _ in 
            print("🔄 Event types changed, updating groups")
            updateChannelGroups() 
        }
        .onChange(of: subscriptionManager.objectWillChange) { _ in
            print("🔄 SubscriptionManager changed, updating groups")
            updateChannelGroups()
        }
    }

    // FIXED: Break down complex view into simpler parts
    @ViewBuilder
    private var contentViewWrapper: some View {
        VStack(spacing: 0) {
            if totalEventCount > 0 {
                filterBar
            }
            
            connectionStatusBanner
            
            contentView
        }
    }
    
    // FIXED: Extracted filter bar
    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $selectedReadFilter) {
                Text("All").tag(AlertFilter.all)
                Text("Unread").tag(AlertFilter.unread)
                Text("Saved").tag(AlertFilter.saved)
            }
            .pickerStyle(SegmentedPickerStyle())
            
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
            
            subscribedChannelsList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // FIXED: Extracted subscribed channels list
    private var subscribedChannelsList: some View {
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
                selectedAreas.removeAll()
                selectedEventTypes.removeAll()
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
    
    private func updateChannelGroups() {
        var groups: [(Channel, [Event])] = []

        for channel in subscriptionManager.subscribedChannels {
            if !selectedAreas.isEmpty, !selectedAreas.contains(channel.area) {
                continue
            }

            if !selectedEventTypes.isEmpty, !selectedEventTypes.contains(channel.eventTypeDisplay) {
                continue
            }

            let allEvents = subscriptionManager.getEvents(channelId: channel.id)

            let filteredEvents: [Event] = {
                switch selectedReadFilter {
                case .all:
                    return allEvents
                case .unread:
                    return allEvents.filter { !$0.isRead }
                case .saved:
                    return allEvents.filter { $0.isSaved }
                }
            }()

            if filteredEvents.isEmpty {
                continue
            }

            groups.append((channel, filteredEvents))
        }

        channelGroups = groups.sorted {
            ($0.1.first?.timestamp ?? 0) > ($1.1.first?.timestamp ?? 0)
        }
    }
    
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
        
        let newEventObserver = NotificationCenter.default.addObserver(
            forName: .newEventReceived,
            object: nil,
            queue: OperationQueue.main
        ) { [self] _ in
            print("🔔 New event received notification")
            self.updateChannelGroups()
        }
        
        _ = NotificationCenter.default.addObserver(
            forName: .eventsMarkedAsRead,
            object: nil,
            queue: OperationQueue.main
        ) { [self] _ in
            print("✅ Events marked as read notification")
            self.updateChannelGroups()
        }
        
        eventObserver = newEventObserver
        
        print("📱 AlertsView: Notification observers setup complete")
    }
    
    private func removeNotificationObservers() {
        if let observer = eventObserver {
            NotificationCenter.default.removeObserver(observer)
            eventObserver = nil
        }
        
        NotificationCenter.default.removeObserver(self, name: .eventsMarkedAsRead, object: nil)
        
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
        formatter.timeZone = TimeZone.current
        return formatter
    }()
    
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.2))
                    .frame(width: 44, height: 44)
                
                Text(iconText)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(iconColor)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(channel.eventTypeDisplay)
                        .font(.system(size: 16, weight: unreadCount > 0 ? .bold : .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    if let event = lastEvent {
                        Text(formatTime(event.date))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                if let area = lastEvent?.areaDisplay ?? lastEvent?.area {
                    Text(area)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                if let event = lastEvent {
                    Text(event.message)
                        .font(.system(size: 14, weight: unreadCount > 0 ? .medium : .regular))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            
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

// MARK: - Filter Sheet

struct FilterSheetView: View {
    @Binding var selectedAreas: Set<String>
    @Binding var selectedEventTypes: Set<String>

    let availableAreas: [String]
    let availableEventTypes: [String]

    @Environment(\.presentationMode) var presentationMode
    
    @State private var isAreaExpanded = false
    @State private var isEventTypeExpanded = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    DisclosureGroup(
                        isExpanded: $isAreaExpanded,
                        content: {
                            ForEach(availableAreas, id: \.self) { area in
                                MultipleSelectionRow(
                                    title: area,
                                    isSelected: selectedAreas.contains(area)
                                ) {
                                    toggle(&selectedAreas, value: area)
                                }
                            }
                        },
                        label: {
                            HStack {
                                Text("Filter by Area")
                                    .font(.headline)
                                Spacer()
                                if !selectedAreas.isEmpty {
                                    Text("\(selectedAreas.count) selected")
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.blue.opacity(0.1))
                                        .cornerRadius(12)
                                }
                            }
                        }
                    )
                }

                Section {
                    DisclosureGroup(
                        isExpanded: $isEventTypeExpanded,
                        content: {
                            ForEach(availableEventTypes, id: \.self) { type in
                                MultipleSelectionRow(
                                    title: type,
                                    isSelected: selectedEventTypes.contains(type)
                                ) {
                                    toggle(&selectedEventTypes, value: type)
                                }
                            }
                        },
                        label: {
                            HStack {
                                Text("Filter by Event Type")
                                    .font(.headline)
                                Spacer()
                                if !selectedEventTypes.isEmpty {
                                    Text("\(selectedEventTypes.count) selected")
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.blue.opacity(0.1))
                                        .cornerRadius(12)
                                }
                            }
                        }
                    )
                }

                Section {
                    Button("Clear All Filters") {
                        selectedAreas.removeAll()
                        selectedEventTypes.removeAll()
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationTitle("Filters")
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

    private func toggle(_ set: inout Set<String>, value: String) {
        if set.contains(value) {
            set.remove(value)
        } else {
            set.insert(value)
        }
    }
}

struct MultipleSelectionRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundColor(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.blue)
                }
            }
        }
    }
}

enum AlertFilter {
    case all
    case unread
    case saved
}
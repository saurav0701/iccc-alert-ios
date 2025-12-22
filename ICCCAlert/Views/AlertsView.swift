import SwiftUI

struct AlertsView: View {
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var webSocketService = WebSocketService.shared
    
    // ✅ NEW: VA/VTS filter instead of read/unread
    @State private var selectedSystemFilter: SystemFilter = .all
    @State private var selectedAreas: Set<String> = []
    @State private var selectedEventTypes: Set<String> = []
    @State private var showOnlySaved = false  // ✅ Separate saved toggle

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
        if selectedSystemFilter != .all { count += 1 }
        if showOnlySaved { count += 1 }
        if !selectedAreas.isEmpty { count += 1 }
        if !selectedEventTypes.isEmpty { count += 1 }
        return count
    }
    
    // ✅ VTS event types (GPS/Vehicle tracking)
    private let vtsEventTypes = ["off-route", "tamper", "overspeed"]
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // ✅ IMPROVED: Compact filter bar
                if totalEventCount > 0 {
                    filterBar
                }
                
                // Connection Status
                connectionStatusBanner
                
                // Content
                contentView
            }
            .navigationTitle("Alerts")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        // ✅ Saved filter toggle (quick access)
                        Button(action: { showOnlySaved.toggle() }) {
                            Image(systemName: showOnlySaved ? "bookmark.fill" : "bookmark")
                                .foregroundColor(showOnlySaved ? .yellow : .gray)
                                .font(.system(size: 18))
                        }
                        
                        // Mark all read (only show if unread exists)
                        if !hasNoUnread {
                            Button(action: markAllAsRead) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.blue)
                                    .font(.system(size: 18))
                            }
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
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear {
            print("📱 AlertsView: Appeared")
            handleViewAppear()
        }
        .onDisappear {
            print("📱 AlertsView: Disappeared")
            removeNotificationObservers()
        }
        .onChange(of: selectedSystemFilter) { _ in updateChannelGroups() }
        .onChange(of: showOnlySaved) { _ in updateChannelGroups() }
        .onChange(of: selectedAreas) { _ in updateChannelGroups() }
        .onChange(of: selectedEventTypes) { _ in updateChannelGroups() }
    }
    
    // ✅ NEW: Improved filter bar with VA/VTS
    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                // VA/VTS System Filter - Stretched to fill available space
                Picker("", selection: $selectedSystemFilter) {
                    Text("All").tag(SystemFilter.all)
                    Text("VA").tag(SystemFilter.va)
                    Text("VTS").tag(SystemFilter.vts)
                }
                .pickerStyle(SegmentedPickerStyle())
                
                // Advanced Filters Button
                Button(action: { showFilterSheet = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 18))
                        
                        if activeFilterCount > 0 {
                            Text("\(activeFilterCount)")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .frame(width: 18, height: 18)
                                .background(Color.blue)
                                .clipShape(Circle())
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.1))
                    .foregroundColor(.blue)
                    .cornerRadius(8)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            
            // ✅ Active filter chips
            if activeFilterCount > 0 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if selectedSystemFilter != .all {
                            FilterChip(
                                title: selectedSystemFilter == .va ? "VA Only" : "VTS Only",
                                icon: selectedSystemFilter == .va ? "camera.fill" : "location.fill",
                                color: selectedSystemFilter == .va ? .purple : .orange
                            ) {
                                selectedSystemFilter = .all
                            }
                        }
                        
                        if showOnlySaved {
                            FilterChip(
                                title: "Saved",
                                icon: "bookmark.fill",
                                color: .yellow
                            ) {
                                showOnlySaved = false
                            }
                        }
                        
                        if !selectedAreas.isEmpty {
                            FilterChip(
                                title: "\(selectedAreas.count) Area\(selectedAreas.count > 1 ? "s" : "")",
                                icon: "map.fill",
                                color: .green
                            ) {
                                selectedAreas.removeAll()
                            }
                        }
                        
                        if !selectedEventTypes.isEmpty {
                            FilterChip(
                                title: "\(selectedEventTypes.count) Type\(selectedEventTypes.count > 1 ? "s" : "")",
                                icon: "tag.fill",
                                color: .blue
                            ) {
                                selectedEventTypes.removeAll()
                            }
                        }
                        
                        // Clear all button
                        Button(action: clearAllFilters) {
                            Text("Clear All")
                                .font(.caption)
                                .foregroundColor(.red)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.red.opacity(0.1))
                                .cornerRadius(8)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 4)
            }
        }
        .padding(.bottom, 8)
        .background(Color(.systemBackground))
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 2)
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
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.orange)
                    .foregroundColor(.white)
                    .cornerRadius(6)
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
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.1))
            }
        }
    }
    
    private var noSubscriptionsView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.gray.opacity(0.1))
                    .frame(width: 100, height: 100)
                Image(systemName: "bell.slash.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.gray)
            }
            
            Text("No Subscriptions")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("Subscribe to channels to receive alerts")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            NavigationLink(destination: ChannelsView()) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("Browse Channels")
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.blue)
                .cornerRadius(10)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var noFilteredEventsView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 100, height: 100)
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.blue)
            }
            
            Text("No Matching Events")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("Try adjusting your filters to see more events")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Button(action: clearAllFilters) {
                HStack {
                    Image(systemName: "xmark.circle.fill")
                    Text("Clear All Filters")
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.blue)
                .cornerRadius(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
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
                .contextMenu {
                    Button(action: {
                        subscriptionManager.markAsRead(channelId: group.channel.id)
                        updateChannelGroups()
                    }) {
                        Label("Mark as Read", systemImage: "checkmark.circle")
                    }
                    
                    Button(action: {
                        subscriptionManager.unsubscribe(channelId: group.channel.id)
                        updateChannelGroups()
                    }) {
                        Label("Unsubscribe", systemImage: "bell.slash.fill")
                    }
                }
            }
        }
        .listStyle(PlainListStyle())
    }
    
    private func updateChannelGroups() {
        var groups: [(Channel, [Event])] = []

        for channel in subscriptionManager.subscribedChannels {
            // Apply VA/VTS filter
            let isVtsChannel = vtsEventTypes.contains(channel.eventType)
            
            switch selectedSystemFilter {
            case .va:
                if isVtsChannel { continue }
            case .vts:
                if !isVtsChannel { continue }
            case .all:
                break
            }
            
            if !selectedAreas.isEmpty, !selectedAreas.contains(channel.area) {
                continue
            }

            if !selectedEventTypes.isEmpty, !selectedEventTypes.contains(channel.eventTypeDisplay) {
                continue
            }

            let allEvents = subscriptionManager.getEvents(channelId: channel.id)

            let filteredEvents = showOnlySaved ? 
                allEvents.filter { $0.isSaved } : 
                allEvents

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
    
    private func clearAllFilters() {
        selectedSystemFilter = .all
        showOnlySaved = false
        selectedAreas.removeAll()
        selectedEventTypes.removeAll()
    }
    
    private func handleViewAppear() {
        connectIfNeeded()
        updateChannelGroups()
        setupNotificationObservers()
        
        NotificationManager.shared.updateBadgeCount()
        
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

struct FilterChip: View {
    let title: String
    let icon: String
    let color: Color
    let onRemove: () -> Void
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
            
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
            
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color)
        .cornerRadius(8)
    }
}

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
            // Channel Icon
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.2))
                    .frame(width: 48, height: 48)
                
                Text(iconText)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(iconColor)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(channel.eventTypeDisplay)
                        .font(.system(size: 17, weight: unreadCount > 0 ? .bold : .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    if let event = lastEvent {
                        Text(dateFormatter.string(from: event.date))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if let area = lastEvent?.areaDisplay ?? lastEvent?.area {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(area)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                
                // Last Event Message
                if let event = lastEvent {
                    Text(event.message)
                        .font(.system(size: 14, weight: unreadCount > 0 ? .medium : .regular))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            if unreadCount > 0 {
                Text("\(unreadCount)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .frame(minWidth: 24, minHeight: 24)
                    .padding(.horizontal, 8)
                    .background(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.blue, Color.blue.opacity(0.8)]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 10)
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
                                Image(systemName: "map.fill")
                                    .foregroundColor(.green)
                                Text("Filter by Area")
                                    .font(.headline)
                                Spacer()
                                if !selectedAreas.isEmpty {
                                    Text("\(selectedAreas.count)")
                                        .font(.caption)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                        .frame(width: 24, height: 24)
                                        .background(Color.green)
                                        .clipShape(Circle())
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
                                Image(systemName: "tag.fill")
                                    .foregroundColor(.blue)
                                Text("Filter by Event Type")
                                    .font(.headline)
                                Spacer()
                                if !selectedEventTypes.isEmpty {
                                    Text("\(selectedEventTypes.count)")
                                        .font(.caption)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                        .frame(width: 24, height: 24)
                                        .background(Color.blue)
                                        .clipShape(Circle())
                                }
                            }
                        }
                    )
                }

                Section {
                    Button(action: {
                        selectedAreas.removeAll()
                        selectedEventTypes.removeAll()
                    }) {
                        HStack {
                            Image(systemName: "xmark.circle.fill")
                            Text("Clear All Filters")
                        }
                        .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Advanced Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .font(.system(size: 17, weight: .semibold))
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
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.blue)
                }
            }
        }
    }
}
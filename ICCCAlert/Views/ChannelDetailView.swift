import SwiftUI

struct ChannelDetailView: View {
    let channel: Channel
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var webSocketService = WebSocketService.shared
    @StateObject private var filterState = FilterState()
    
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var pendingEventsCount = 0
    @State private var showNewEventsBanner = false
    @State private var selectedEvent: Event? = nil
    @State private var showingImageDetail = false
    @State private var showingMapView = false
    @State private var refreshTrigger = UUID()
    @State private var showFilterSheet = false
    @State private var showHeaderMenu = false
    @State private var viewMode: ViewMode = .grid
    
    @State private var eventObserver: NSObjectProtocol?
    
    @Environment(\.presentationMode) var presentationMode
    
    enum ViewMode {
        case grid
        case timeline
    }
    
    var isSubscribed: Bool {
        subscriptionManager.isSubscribed(channelId: channel.id)
    }
    
    var isMuted: Bool {
        subscriptionManager.isChannelMuted(channelId: channel.id)
    }
    
    var events: [Event] {
        let allEvents = subscriptionManager.getEvents(channelId: channel.id)
        return allEvents.filter { event in
            filterState.matchesEvent(event, channel: channel, vtsEventTypes: vtsEventTypes)
        }
    }
    
    var unreadCount: Int {
        subscriptionManager.getUnreadCount(channelId: channel.id)
    }
    
    var isGpsChannel: Bool {
        return channel.eventType == "off-route" || 
               channel.eventType == "tamper" || 
               channel.eventType == "overspeed"
    }
    
    private let vtsEventTypes = ["off-route", "tamper", "overspeed"]
    
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
                Button(action: { showHeaderMenu = true }) {
                    VStack(spacing: 2) {
                        HStack(spacing: 4) {
                            Text(channel.eventTypeDisplay)
                                .font(.headline)
                            Image(systemName: "chevron.down")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
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
            if event.isGpsEvent {
                GPSEventMapView(event: event)
            } else {
                ImageDetailView(event: event)
            }
        }
        .sheet(isPresented: $showHeaderMenu) {
            ChannelHeaderMenuView(
                viewMode: $viewMode,
                filterState: filterState,
                showFilterSheet: $showFilterSheet,
                channel: channel
            )
        }
        .sheet(isPresented: $showFilterSheet) {
            FilterSheetView(
                filterState: filterState,
                availableAreas: [channel.area],
                availableEventTypes: [channel.eventTypeDisplay]
            )
        }
        .onAppear {
            if isSubscribed {
                subscriptionManager.markAsRead(channelId: channel.id)
                NotificationManager.shared.clearNotifications(for: channel.id)
                NotificationManager.shared.updateBadgeCount()
            }
            setupNotificationObserver()
        }
        .onDisappear {
            removeNotificationObserver()
            
            if isSubscribed {
                subscriptionManager.markAsRead(channelId: channel.id)
            }
        }
        .onChange(of: filterState.timeFilter) { _ in refreshTrigger = UUID() }
        .onChange(of: filterState.showOnlySaved) { _ in refreshTrigger = UUID() }
        .id(refreshTrigger)
    }
    
    private var headerAreaText: String? {
        let latestEvent = events.first
        return latestEvent?.areaDisplay ?? latestEvent?.area
    }
    
    private var eventsListView: some View {
        VStack(spacing: 0) {
            if filterState.activeFilterCount > 0 {
                activeFiltersBar
            }
            
            if events.isEmpty {
                emptyEventsView
            } else {
                if viewMode == .timeline {
                    timelineView
                } else {
                    gridView
                }
            }
        }
        .background(Color(.systemGroupedBackground))
    }
    
    private var activeFiltersBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if filterState.timeFilter != .all {
                    FilterChip(
                        title: filterState.timeFilter.displayText,
                        icon: "clock.fill",
                        color: .blue
                    ) {
                        filterState.timeFilter = .all
                    }
                }
                
                if filterState.showOnlySaved {
                    FilterChip(
                        title: "Saved",
                        icon: "bookmark.fill",
                        color: .yellow
                    ) {
                        filterState.showOnlySaved = false
                    }
                }
                
                Button(action: { filterState.clearAll() }) {
                    Text("Clear")
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(.systemBackground))
    }
    
    private var gridView: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(events) { event in
                    if event.isGpsEvent {
                        GPSEventCard(
                            event: event,
                            channel: channel,
                            showTimestamp: true,
                            onTap: {
                                selectedEvent = event
                                showingMapView = true
                            },
                            onSaveToggle: {
                                if let eventId = event.id {
                                    subscriptionManager.toggleSaved(eventId: eventId, channelId: channel.id)
                                    refreshTrigger = UUID()
                                }
                            }
                        )
                    } else {
                        ModernEventCard(
                            event: event,
                            channel: channel,
                            showTimestamp: true,
                            onTap: {
                                selectedEvent = event
                                showingImageDetail = true
                            },
                            onSaveToggle: {
                                if let eventId = event.id {
                                    subscriptionManager.toggleSaved(eventId: eventId, channelId: channel.id)
                                    refreshTrigger = UUID()
                                }
                            }
                        )
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
        }
    }
    
    private var timelineView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groupedEventsByDate, id: \.key) { dateGroup in
                    // Date Header
                    HStack {
                        Text(dateGroup.key)
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        Spacer()
                        
                        Text("\(dateGroup.value.count) events")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                    .background(Color(.systemGroupedBackground))
                    
                    // Events for this date
                    ForEach(dateGroup.value) { event in
                        TimelineEventRow(
                            event: event,
                            channel: channel,
                            isLast: event.id == dateGroup.value.last?.id,
                            onTap: {
                                selectedEvent = event
                                if event.isGpsEvent {
                                    showingMapView = true
                                } else {
                                    showingImageDetail = true
                                }
                            },
                            onSaveToggle: {
                                if let eventId = event.id {
                                    subscriptionManager.toggleSaved(eventId: eventId, channelId: channel.id)
                                    refreshTrigger = UUID()
                                }
                            }
                        )
                    }
                }
            }
            .padding(.top, 8)
        }
    }
    
    private var groupedEventsByDate: [(key: String, value: [Event])] {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: events) { event -> String in
            if calendar.isDateInToday(event.date) {
                return "Today"
            } else if calendar.isDateInYesterday(event.date) {
                return "Yesterday"
            } else {
                return formatter.string(from: event.date)
            }
        }
        
        return grouped.sorted { first, second in
            guard let firstEvent = first.value.first,
                  let secondEvent = second.value.first else {
                return false
            }
            return firstEvent.date > secondEvent.date
        }
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
                
                Image(systemName: isGpsChannel ? "location.slash" : "tray")
                    .font(.system(size: 40))
                    .foregroundColor(.blue)
            }
            
            Text(filterState.activeFilterCount > 0 ? "No Matching Events" : "No Events Yet")
                .font(.title2)
                .fontWeight(.bold)
            
            Text(filterState.activeFilterCount > 0 ? 
                 "Try adjusting your filters" :
                 (isGpsChannel ? 
                  "GPS alerts will appear here when vehicles trigger geofence violations" :
                  "New events will appear here automatically when they occur"))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            if filterState.activeFilterCount > 0 {
                Button(action: { filterState.clearAll() }) {
                    Text("Clear Filters")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.blue)
                        .cornerRadius(10)
                }
            }
            
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
                
                Image(systemName: isGpsChannel ? "location.fill" : "bell.fill")
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
            
            Text(isGpsChannel ? 
                 "Get real-time GPS alerts for this vehicle tracking channel" :
                 "Get real-time alerts for this channel")
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
                Image(systemName: isGpsChannel ? "location.fill.viewfinder" : "bell.badge.fill")
                    .font(.system(size: 16))
                
                Text("\(pendingEventsCount) new \(isGpsChannel ? "alert" : "event")\(pendingEventsCount == 1 ? "" : "s")")
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
        case "overspeed": return Color(hex: "FF9800")
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

// MARK: - Channel Header Menu

struct ChannelHeaderMenuView: View {
    @Binding var viewMode: ChannelDetailView.ViewMode
    @ObservedObject var filterState: FilterState
    @Binding var showFilterSheet: Bool
    let channel: Channel
    
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("View Options")) {
                    Button(action: {
                        viewMode = .grid
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        HStack {
                            Image(systemName: "square.grid.2x2")
                                .foregroundColor(.blue)
                            Text("Grid View")
                            Spacer()
                            if viewMode == .grid {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    
                    Button(action: {
                        viewMode = .timeline
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        HStack {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundColor(.purple)
                            Text("Timeline View")
                            Spacer()
                            if viewMode == .timeline {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
                
                Section(header: Text("Quick Filters")) {
                    Button(action: {
                        filterState.showOnlySaved.toggle()
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        HStack {
                            Image(systemName: filterState.showOnlySaved ? "bookmark.fill" : "bookmark")
                                .foregroundColor(.yellow)
                            Text("Saved Only")
                            Spacer()
                            if filterState.showOnlySaved {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    
                    Button(action: {
                        showFilterSheet = true
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        HStack {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .foregroundColor(.blue)
                            Text("Advanced Filters")
                            Spacer()
                            if filterState.activeFilterCount > 0 {
                                Text("\(filterState.activeFilterCount)")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundColor(.white)
                                    .frame(width: 22, height: 22)
                                    .background(Color.blue)
                                    .clipShape(Circle())
                            }
                        }
                    }
                }
                
                Section(header: Text("Channel Info")) {
                    HStack {
                        Text("Event Type")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(channel.eventTypeDisplay)
                    }
                    
                    HStack {
                        Text("Area")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(channel.areaDisplay)
                    }
                }
            }
            .navigationTitle("Options")
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

// MARK: - Timeline Event Row

struct TimelineEventRow: View {
    let event: Event
    let channel: Channel
    let isLast: Bool
    let onTap: () -> Void
    let onSaveToggle: () -> Void
    
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Timeline indicator
            VStack(spacing: 0) {
                Circle()
                    .fill(eventColor)
                    .frame(width: 12, height: 12)
                
                if !isLast {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 2)
                }
            }
            
            // Event content
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(timeFormatter.string(from: event.date))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(eventColor)
                    
                    Spacer()
                    
                    Button(action: onSaveToggle) {
                        Image(systemName: event.isSaved ? "bookmark.fill" : "bookmark")
                            .font(.caption)
                            .foregroundColor(event.isSaved ? .yellow : .gray)
                    }
                }
                
                Button(action: onTap) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(event.location)
                            .font(.body)
                            .foregroundColor(.primary)
                            .lineLimit(2)
                        
                        if event.isGpsEvent {
                            HStack(spacing: 8) {
                                Image(systemName: "location.fill")
                                    .font(.caption)
                                if let alertLoc = event.gpsAlertLocation {
                                    Text(String(format: "%.6f, %.6f", alertLoc.lat, alertLoc.lng))
                                        .font(.caption)
                                }
                            }
                            .foregroundColor(.secondary)
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.vertical, 8)
        }
        .padding(.horizontal)
        .background(Color(.systemBackground))
    }
    
    private var eventColor: Color {
        switch (event.type ?? channel.eventType).lowercased() {
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
        case "overspeed": return Color(hex: "FF9800")
        default: return Color(hex: "9E9E9E")
        }
    }
}
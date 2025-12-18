import SwiftUI

struct ChannelsView: View {
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var webSocketService = WebSocketService.shared
    @State private var searchText = ""
    @State private var selectedArea: String? = nil
    @State private var expandedAreas: Set<String> = []
    
    // All available areas
    private let areas = [
        ("barkasayal", "Barka Sayal"),
        ("argada", "Argada"),
        ("northkaranpura", "North Karanpura"),
        ("bokarokargali", "Bokaro & Kargali"),
        ("kathara", "Kathara"),
        ("giridih", "Giridih"),
        ("amrapali", "Amrapali & Chandragupta"),
        ("magadh", "Magadh & Sanghmitra"),
        ("rajhara", "Rajhara"),
        ("kuju", "Kuju"),
        ("hazaribagh", "Hazaribagh"),
        ("rajrappa", "Rajrappa"),
        ("dhori", "Dhori"),
        ("piparwar", "Piparwar")
    ]
    
    // Event types for each area
    private let eventTypes = [
        ("cd", "Crowd Detection"),
        ("vd", "Vehicle Detection"),
        ("pd", "Person Detection"),
        ("id", "Intrusion Detection"),
        ("vc", "Vehicle Congestion"),
        ("ls", "Loading Status"),
        ("us", "Unloading Status"),
        ("ct", "Camera Tampering"),
        ("sh", "Safety Hazard"),
        ("ii", "Insufficient Illumination"),
        ("off-route", "Off-Route Alert"),
        ("tamper", "Tamper Alert")
    ]
    
    var filteredAreas: [(String, String)] {
        if searchText.isEmpty {
            return areas
        }
        return areas.filter { area in
            area.1.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Connection Status Banner
                connectionStatusBanner
                
                // Search Bar
                searchBar
                
                // Channels List with Dropdown
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredAreas, id: \.0) { area in
                            AreaSection(
                                area: area,
                                eventTypes: eventTypes,
                                isExpanded: expandedAreas.contains(area.0),
                                onToggle: {
                                    withAnimation {
                                        if expandedAreas.contains(area.0) {
                                            expandedAreas.remove(area.0)
                                        } else {
                                            expandedAreas.insert(area.0)
                                        }
                                    }
                                },
                                subscriptionManager: subscriptionManager
                            )
                            
                            Divider()
                        }
                    }
                }
            }
            .navigationTitle("Channels")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        // Stats badge
                        if subscriptionManager.subscribedChannels.count > 0 {
                            Text("\(subscriptionManager.getTotalEventCount())")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .onAppear {
            if !webSocketService.isConnected {
                webSocketService.connect()
            }
        }
    }
    
    // MARK: - Connection Status Banner
    
    private var connectionStatusBanner: some View {
        Group {
            if !webSocketService.isConnected {
                HStack {
                    Image(systemName: "wifi.slash")
                    Text(webSocketService.connectionStatus)
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
                    Text("\(subscriptionManager.subscribedChannels.count) subscribed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.1))
            }
        }
    }
    
    // MARK: - Search Bar
    
    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.gray)
            TextField("Search areas...", text: $searchText)
                .textFieldStyle(PlainTextFieldStyle())
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                }
            }
        }
        .padding(8)
        .background(Color(.systemGray6))
        .cornerRadius(10)
        .padding()
    }
}

// MARK: - Area Section (Expandable)

struct AreaSection: View {
    let area: (String, String)
    let eventTypes: [(String, String)]
    let isExpanded: Bool
    let onToggle: () -> Void
    let subscriptionManager: SubscriptionManager
    
    private var subscribedCount: Int {
        subscriptionManager.subscribedChannels.filter { $0.area == area.0 }.count
    }
    
    private var totalEvents: Int {
        subscriptionManager.subscribedChannels
            .filter { $0.area == area.0 }
            .reduce(0) { total, channel in
                total + subscriptionManager.getEvents(channelId: channel.id).count
            }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Area Header (Clickable)
            Button(action: onToggle) {
                HStack(spacing: 12) {
                    // Area Icon
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.2))
                            .frame(width: 50, height: 50)
                        
                        Image(systemName: "location.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.blue)
                    }
                    
                    // Area Info
                    VStack(alignment: .leading, spacing: 4) {
                        Text(area.1)
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        HStack(spacing: 8) {
                            if subscribedCount > 0 {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                    Text("\(subscribedCount) subscribed")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            } else {
                                Text("\(eventTypes.count) event types")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            if totalEvents > 0 {
                                Text("•")
                                    .foregroundColor(.secondary)
                                Text("\(totalEvents) events")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    Spacer()
                    
                    // Expand/Collapse Icon
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.gray)
                }
                .padding()
                .background(Color(.systemBackground))
            }
            .buttonStyle(PlainButtonStyle())
            
            // Event Types List (Expandable)
            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(eventTypes, id: \.0) { eventType in
                        EventTypeRow(
                            area: area,
                            eventType: eventType,
                            subscriptionManager: subscriptionManager
                        )
                        
                        if eventType.0 != eventTypes.last?.0 {
                            Divider()
                                .padding(.leading, 80)
                        }
                    }
                }
                .background(Color(.systemGray6).opacity(0.3))
            }
        }
    }
}

// MARK: - Event Type Row

struct EventTypeRow: View {
    let area: (String, String)
    let eventType: (String, String)
    let subscriptionManager: SubscriptionManager
    
    private var channelId: String {
        "\(area.0)_\(eventType.0)"
    }
    
    private var channel: Channel {
        Channel(
            id: channelId,
            area: area.0,
            areaDisplay: area.1,
            eventType: eventType.0,
            eventTypeDisplay: eventType.1,
            description: "\(area.1) - \(eventType.1)",
            isSubscribed: isSubscribed,
            isMuted: false,
            isPinned: false
        )
    }
    
    private var isSubscribed: Bool {
        subscriptionManager.isSubscribed(channelId: channelId)
    }
    
    private var unreadCount: Int {
        subscriptionManager.getUnreadCount(channelId: channelId)
    }
    
    private var eventCount: Int {
        subscriptionManager.getEvents(channelId: channelId).count
    }
    
    var body: some View {
        NavigationLink(
            destination: ChannelDetailView(channel: channel)
        ) {
            HStack(spacing: 12) {
                // Event Type Icon
                ZStack {
                    Circle()
                        .fill(iconColor.opacity(0.2))
                        .frame(width: 40, height: 40)
                    
                    Text(iconText)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(iconColor)
                }
                
                // Event Type Info
                VStack(alignment: .leading, spacing: 4) {
                    Text(eventType.1)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    
                    if isSubscribed {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.green)
                            
                            if eventCount > 0 {
                                Text("\(eventCount) events")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Subscribed")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else {
                        Text("Tap to subscribe")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // Unread Badge
                if unreadCount > 0 {
                    Text("\(unreadCount)")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.red)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
    }
    
    private var iconText: String {
        let type = eventType.0.uppercased()
        if type.count <= 2 {
            return type
        }
        return String(type.prefix(2))
    }
    
    private var iconColor: Color {
        switch eventType.0.lowercased() {
        case "cd": return Color(hex: "FF5722")
        case "id": return Color(hex: "F44336")
        case "ct": return Color(hex: "E91E63")
        case "sh": return Color(hex: "FF9800")
        case "vd": return Color(hex: "2196F3")
        case "pd": return Color(hex: "4CAF50")
        case "vc": return Color(hex: "FFC107")
        case "ii": return Color(hex: "9C27B0")
        case "ls": return Color(hex: "00BCD4")
        case "us": return Color(hex: "3F51B5")
        case "off-route": return Color(hex: "FF5722")
        case "tamper": return Color(hex: "F44336")
        default: return Color(hex: "9E9E9E")
        }
    }
}
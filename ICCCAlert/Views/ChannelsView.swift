import SwiftUI

struct ChannelsView: View {
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var webSocketService = WebSocketService.shared
    @State private var searchText = ""
    @State private var selectedCategory: String? = nil
    @State private var refreshTrigger = UUID()
    
    var availableChannels: [Channel] {
        SubscriptionManager.getAllAvailableChannels()
    }
    
    var categories: [String] {
        Array(Set(availableChannels.map { $0.eventTypeDisplay })).sorted()
    }
    
    var filteredChannels: [Channel] {
        var channels = availableChannels
        
        // Apply category filter
        if let category = selectedCategory {
            channels = channels.filter { $0.eventTypeDisplay == category }
        }
        
        // Apply search filter
        if !searchText.isEmpty {
            channels = channels.filter {
                $0.areaDisplay.localizedCaseInsensitiveContains(searchText) ||
                $0.eventTypeDisplay.localizedCaseInsensitiveContains(searchText)
            }
        }
        
        // Mark subscribed channels
        let subscribedIds = Set(subscriptionManager.subscribedChannels.map { $0.id })
        return channels.map { channel in
            var updated = channel
            updated.isSubscribed = subscribedIds.contains(channel.id)
            return updated
        }
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Connection Status Banner
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
                
                // Search Bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.gray)
                    TextField("Search channels", text: $searchText)
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
                
                // Category Filter
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        FilterChip(title: "All", isSelected: selectedCategory == nil) {
                            selectedCategory = nil
                        }
                        ForEach(categories, id: \.self) { category in
                            FilterChip(title: category, isSelected: selectedCategory == category) {
                                selectedCategory = category
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom)
                
                // Channels List
                if filteredChannels.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 50))
                            .foregroundColor(.gray)
                        Text("No channels found")
                            .font(.headline)
                        Text("Try adjusting your search or filters")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filteredChannels) { channel in
                        NavigationLink(
                            destination: ChannelDetailView(channel: channel)
                        ) {
                            ChannelRowView(channel: channel)
                        }
                    }
                    .id(refreshTrigger)
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
            // Connect WebSocket if not connected
            if !webSocketService.isConnected {
                webSocketService.connect()
            }
        }
    }
}

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isSelected ? Color.blue : Color(.systemGray6))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(20)
        }
    }
}

struct ChannelRowView: View {
    let channel: Channel
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    
    var unreadCount: Int {
        subscriptionManager.getUnreadCount(channelId: channel.id)
    }
    
    var lastEvent: Event? {
        subscriptionManager.getLastEvent(channelId: channel.id)
    }
    
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
            
            // Channel Info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(channel.areaDisplay)
                        .font(.headline)
                    
                    if channel.isSubscribed {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                    
                    Spacer()
                    
                    if unreadCount > 0 {
                        Text("\(unreadCount)")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.red)
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                }
                
                Text(channel.eventTypeDisplay)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                if let event = lastEvent {
                    Text(event.location)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                HStack {
                    Text(channel.eventTypeDisplay)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(iconColor.opacity(0.1))
                        .foregroundColor(iconColor)
                        .cornerRadius(4)
                    
                    if let event = lastEvent {
                        Spacer()
                        Text(timeAgo(from: event.date))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.gray)
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
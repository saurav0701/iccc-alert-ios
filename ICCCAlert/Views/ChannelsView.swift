import SwiftUI

struct ChannelsView: View {
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var webSocketService = WebSocketService.shared
    @State private var searchText = ""
    
    var availableAreas: [(area: String, display: String)] {
        let areas = [
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
        
        if searchText.isEmpty {
            return areas
        }
        
        return areas.filter { $0.display.localizedCaseInsensitiveContains(searchText) }
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Connection Status Banner
                connectionStatusBanner
                
                // Search Bar
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
                
                // Areas List
                if availableAreas.isEmpty {
                    emptySearchView
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(availableAreas, id: \.area) { area in
                                AreaCard(
                                    area: area.area,
                                    areaDisplay: area.display
                                )
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Channels")
            .navigationBarTitleDisplayMode(.large)
        }
        .onAppear {
            if !webSocketService.isConnected {
                webSocketService.connect()
            }
        }
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
    
    private var emptySearchView: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 50))
                .foregroundColor(.gray)
            Text("No areas found")
                .font(.headline)
            Text("Try adjusting your search")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Area Card

struct AreaCard: View {
    let area: String
    let areaDisplay: String
    
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @State private var isExpanded = false
    
    private let eventTypes = [
        ("cd", "Crowd Detection", "FF5722"),
        ("vd", "Vehicle Detection", "2196F3"),
        ("pd", "Person Detection", "4CAF50"),
        ("id", "Intrusion Detection", "F44336"),
        ("vc", "Vehicle Congestion", "FFC107"),
        ("ls", "Loading Status", "00BCD4"),
        ("ct", "Camera Tampering", "E91E63"),
        ("sh", "Safety Hazard", "FF9800"),
        ("ii", "Insufficient Illumination", "9C27B0"),
        ("off-route", "Off-Route Alert", "FF5722"),
        ("tamper", "Tamper Alert", "F44336")
    ]
    
    private var subscribedCount: Int {
        eventTypes.filter { type in
            subscriptionManager.isSubscribed(channelId: "\(area)_\(type.0)")
        }.count
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            Button(action: { withAnimation { isExpanded.toggle() } }) {
                HStack {
                    Text(areaDisplay)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    if subscribedCount > 0 {
                        Text("\(subscribedCount) subscribed")
                            .font(.caption)
                            .foregroundColor(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(4)
                    }
                    
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(.systemBackground))
            }
            
            // Event Types (Expandable)
            if isExpanded {
                VStack(spacing: 8) {
                    ForEach(eventTypes, id: \.0) { type in
                        EventTypeRow(
                            area: area,
                            eventType: type.0,
                            eventTypeDisplay: type.1,
                            colorHex: type.2
                        )
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
            }
        }
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
    }
}

// MARK: - Event Type Row

struct EventTypeRow: View {
    let area: String
    let eventType: String
    let eventTypeDisplay: String
    let colorHex: String
    
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @State private var isSubscribing = false
    
    private var channelId: String {
        "\(area)_\(eventType)"
    }
    
    private var isSubscribed: Bool {
        subscriptionManager.isSubscribed(channelId: channelId)
    }
    
    private var iconText: String {
        let type = eventType.uppercased()
        if type.count <= 2 {
            return type
        }
        return String(type.prefix(2))
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Icon
            ZStack {
                Circle()
                    .fill(Color(hex: colorHex).opacity(0.2))
                    .frame(width: 40, height: 40)
                
                Text(iconText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(hex: colorHex))
            }
            
            // Title
            Text(eventTypeDisplay)
                .font(.subheadline)
                .foregroundColor(.primary)
            
            Spacer()
            
            // Subscribe Button
            Button(action: toggleSubscription) {
                if isSubscribing {
                    ProgressView()
                        .scaleEffect(0.8)
                } else if isSubscribed {
                    Text("Subscribed")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.green.opacity(0.2))
                        .foregroundColor(.green)
                        .cornerRadius(8)
                } else {
                    Text("Subscribe")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            }
            .disabled(isSubscribing)
        }
        .padding(.vertical, 4)
    }
    
    private func toggleSubscription() {
        isSubscribing = true
        
        if isSubscribed {
            // Unsubscribe
            subscriptionManager.unsubscribe(channelId: channelId)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isSubscribing = false
            }
        } else {
            // Subscribe
            let channel = Channel(
                id: channelId,
                area: area,
                areaDisplay: eventTypeDisplay,
                eventType: eventType,
                eventTypeDisplay: eventTypeDisplay,
                description: "\(area) - \(eventTypeDisplay)",
                isSubscribed: true,
                isMuted: false,
                isPinned: false
            )
            
            subscriptionManager.subscribe(channel: channel)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isSubscribing = false
            }
        }
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
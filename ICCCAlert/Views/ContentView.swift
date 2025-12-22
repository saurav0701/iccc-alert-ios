import SwiftUI

struct ContentView: View {
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    
    var body: some View {
        TabView {
            AlertsView()
                .tabItem {
                    Image(systemName: "bell.fill")
                    Text("Alerts")
                }
            
            SavedEventsView()
                .tabItem {
                    Image(systemName: "bookmark.fill")
                    Text("Saved")
                }
            
            ChannelsView()
                .tabItem {
                    Image(systemName: "list.bullet")
                    Text("Channels")
                }
            
            // ✅ NEW: Activity Tab (replaces Debug)
            ActivityView()
                .tabItem {
                    Image(systemName: "clock.fill")
                    Text("Activity")
                }
            
            SettingsView()
                .tabItem {
                    Image(systemName: "gear")
                    Text("Settings")
                }
        }
    }
}

// ✅ Activity View - Shows recent event timeline across all channels
struct ActivityView: View {
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @State private var allEvents: [EventWithChannel] = []
    @State private var selectedEvent: Event?
    @State private var showingDetail = false
    @State private var selectedSystemFilter: SystemFilter = .all
    
    private let vtsEventTypes = ["off-route", "tamper", "overspeed"]
    
    // Get all events sorted by timestamp
    private var filteredEvents: [EventWithChannel] {
        var events: [EventWithChannel] = []
        
        for channel in subscriptionManager.subscribedChannels {
            let channelEvents = subscriptionManager.getEvents(channelId: channel.id)
            for event in channelEvents {
                events.append(EventWithChannel(event: event, channel: channel))
            }
        }
        
        // Apply VA/VTS filter
        events = events.filter { item in
            let isVts = vtsEventTypes.contains(item.event.type ?? "")
            
            switch selectedSystemFilter {
            case .all:
                return true
            case .va:
                return !isVts
            case .vts:
                return isVts
            }
        }
        
        // Sort by timestamp (newest first)
        return events.sorted { $0.event.timestamp > $1.event.timestamp }
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Filter bar
                filterBar
                
                // Content
                if filteredEvents.isEmpty {
                    emptyStateView
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredEvents) { item in
                                ActivityEventRow(
                                    event: item.event,
                                    channel: item.channel,
                                    onTap: {
                                        selectedEvent = item.event
                                        showingDetail = true
                                    }
                                )
                                
                                Divider()
                                    .padding(.leading, 72)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.large)
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .fullScreenCover(item: $selectedEvent) { event in
            if event.isGpsEvent {
                GPSEventMapView(event: event)
            } else {
                ImageDetailView(event: event)
            }
        }
    }
    
    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $selectedSystemFilter) {
                Text("All").tag(SystemFilter.all)
                Text("VA").tag(SystemFilter.va)
                Text("VTS").tag(SystemFilter.vts)
            }
            .pickerStyle(SegmentedPickerStyle())
            
            if selectedSystemFilter != .all {
                Button(action: { selectedSystemFilter = .all }) {
                    Text("Clear")
                        .font(.subheadline)
                        .foregroundColor(.blue)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(8)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 2)
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 100, height: 100)
                Image(systemName: "clock.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.blue)
            }
            
            Text(selectedSystemFilter == .all ? "No Recent Activity" : "No \(selectedSystemFilter == .va ? "VA" : "VTS") Activity")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("Events from your subscribed channels will appear here")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            if selectedSystemFilter != .all {
                Button(action: { selectedSystemFilter = .all }) {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                        Text("Show All")
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
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

// Activity Event Row
struct ActivityEventRow: View {
    let event: Event
    let channel: Channel
    let onTap: () -> Void
    
    @AppStorage("show_timestamps") private var showTimestamps = true
    
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = TimeZone.current
        return formatter
    }()
    
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM dd"
        formatter.timeZone = TimeZone.current
        return formatter
    }()
    
    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                // Icon
                ZStack {
                    Circle()
                        .fill(iconColor.opacity(0.2))
                        .frame(width: 48, height: 48)
                    
                    Image(systemName: event.isGpsEvent ? "location.fill" : "camera.fill")
                        .font(.system(size: 20))
                        .foregroundColor(iconColor)
                }
                
                VStack(alignment: .leading, spacing: 6) {
                    // Event type
                    Text(channel.eventTypeDisplay)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                    
                    // Location/Message
                    Text(event.message)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    
                    // Area
                    if let area = event.areaDisplay ?? event.area {
                        HStack(spacing: 4) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.caption2)
                            Text(area)
                                .font(.caption)
                        }
                        .foregroundColor(.secondary)
                    }
                    
                    // ✅ Timestamp (respect settings)
                    if showTimestamps {
                        Text("\(timeFormatter.string(from: event.date)) • \(dateFormatter.string(from: event.date))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // Saved indicator
                if event.isSaved {
                    Image(systemName: "bookmark.fill")
                        .foregroundColor(.yellow)
                        .font(.system(size: 16))
                }
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(.systemBackground))
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private var iconColor: Color {
        if event.isGpsEvent {
            switch event.type {
            case "off-route": return Color(hex: "FF5722")
            case "tamper": return Color(hex: "F44336")
            case "overspeed": return Color(hex: "FF9800")
            default: return Color.blue
            }
        } else {
            switch event.type?.lowercased() {
            case "cd": return Color(hex: "FF5722")
            case "id": return Color(hex: "F44336")
            case "vd": return Color(hex: "2196F3")
            case "pd": return Color(hex: "4CAF50")
            default: return Color.gray
            }
        }
    }
}

// Helper struct to pair events with channels
struct EventWithChannel: Identifiable {
    let id: UUID = UUID()
    let event: Event
    let channel: Channel
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(AuthManager.shared)
            .environmentObject(WebSocketService.shared)
            .environmentObject(SubscriptionManager.shared)
    }
}
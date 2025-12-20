import SwiftUI

// MARK: - System Filter Enum (shared across views)

enum SystemFilter {
    case all
    case va   // Video Analytics
    case vts  // Vehicle Tracking System
}

// MARK: - Saved Events View

struct SavedEventsView: View {
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @State private var selectedEvent: Event? = nil
    @State private var showingImageDetail = false
    @State private var showingMapView = false
    @State private var refreshTrigger = UUID()
    
    // Filter state
    @State private var selectedSystemFilter: SystemFilter = .all
    
    // VTS event types
    private let vtsEventTypes = ["off-route", "tamper", "overspeed"]
    
    var savedEvents: [Event] {
        let allSaved = subscriptionManager.getSavedEvents()
        
        // Apply VA/VTS filter
        switch selectedSystemFilter {
        case .all:
            return allSaved
        case .va:
            return allSaved.filter { event in
                guard let type = event.type else { return false }
                return !vtsEventTypes.contains(type)
            }
        case .vts:
            return allSaved.filter { event in
                guard let type = event.type else { return false }
                return vtsEventTypes.contains(type)
            }
        }
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Filter bar (if there are saved events)
                if !savedEvents.isEmpty || selectedSystemFilter != .all {
                    filterBar
                }
                
                // Content
                if savedEvents.isEmpty {
                    emptyView
                } else {
                    eventsList
                }
            }
            .navigationTitle("Saved Events")
            .navigationBarTitleDisplayMode(.large)
        }
        .fullScreenCover(item: $selectedEvent) { event in
            if event.isGpsEvent {
                GPSEventMapView(event: event)
            } else {
                ImageDetailView(event: event)
            }
        }
        .id(refreshTrigger)
    }
    
    // MARK: - Filter Bar
    
    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                // VA/VTS System Filter
                Picker("", selection: $selectedSystemFilter) {
                    Text("All").tag(SystemFilter.all)
                    Text("VA").tag(SystemFilter.va)
                    Text("VTS").tag(SystemFilter.vts)
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(maxWidth: 200)
                
                Spacer()
                
                if selectedSystemFilter != .all {
                    Button(action: { selectedSystemFilter = .all }) {
                        Text("Clear")
                            .font(.caption)
                            .foregroundColor(.blue)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(8)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(.systemBackground))
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 2)
    }
    
    // MARK: - Empty View
    
    private var emptyView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            ZStack {
                Circle()
                    .fill(Color.yellow.opacity(0.1))
                    .frame(width: 100, height: 100)
                Image(systemName: "bookmark.slash.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.yellow)
            }
            
            Text(selectedSystemFilter == .all ? "No Saved Events" : "No Saved \(selectedSystemFilter == .va ? "VA" : "VTS") Events")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("Events you bookmark will appear here")
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
    
    // MARK: - Events List
    
    private var eventsList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(savedEvents) { event in
                    if event.isGpsEvent {
                        GPSEventCard(
                            event: event,
                            channel: getChannelForEvent(event),
                            onTap: {
                                selectedEvent = event
                                showingMapView = true
                            },
                            onSaveToggle: {
                                if let eventId = event.id,
                                   let channelId = getChannelId(for: event) {
                                    subscriptionManager.toggleSaved(eventId: eventId, channelId: channelId)
                                    refreshTrigger = UUID()
                                }
                            }
                        )
                    } else {
                        ModernEventCard(
                            event: event,
                            channel: getChannelForEvent(event),
                            onTap: {
                                selectedEvent = event
                                showingImageDetail = true
                            },
                            onSaveToggle: {
                                if let eventId = event.id,
                                   let channelId = getChannelId(for: event) {
                                    subscriptionManager.toggleSaved(eventId: eventId, channelId: channelId)
                                    refreshTrigger = UUID()
                                }
                            }
                        )
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .background(Color(.systemGroupedBackground))
    }
    
    // MARK: - Helper Methods
    
    private func getChannelId(for event: Event) -> String? {
        guard let area = event.area, let type = event.type else { return nil }
        return "\(area)_\(type)"
    }
    
    private func getChannelForEvent(_ event: Event) -> Channel {
        guard let area = event.area, let type = event.type else {
            return Channel(
                id: "unknown",
                area: "unknown",
                areaDisplay: "Unknown Area",
                eventType: "unknown",
                eventTypeDisplay: "Unknown Event",
                description: "",
                isSubscribed: false,
                isMuted: false,
                isPinned: false
            )
        }
        
        let channelId = "\(area)_\(type)"
        
        // Try to find existing channel
        if let existingChannel = subscriptionManager.subscribedChannels.first(where: { $0.id == channelId }) {
            return existingChannel
        }
        
        // Create temporary channel
        return Channel(
            id: channelId,
            area: area,
            areaDisplay: event.areaDisplay ?? area,
            eventType: type,
            eventTypeDisplay: event.typeDisplay ?? type,
            description: "",
            isSubscribed: false,
            isMuted: false,
            isPinned: false
        )
    }
}


struct SavedEventsView_Previews: PreviewProvider {
    static var previews: some View {
        SavedEventsView()
    }
}
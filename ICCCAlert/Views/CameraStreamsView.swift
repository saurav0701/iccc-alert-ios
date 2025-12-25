import SwiftUI

struct CameraStreamsView: View {
    @StateObject private var cameraManager = CameraManager.shared
    @StateObject private var webSocketService = WebSocketService.shared
    
    @State private var searchText = ""
    @State private var showOnlineOnly = false
    @State private var selectedArea: String? = nil
    @State private var refreshID = UUID()
    
    var filteredAreas: [String] {
        var areas = cameraManager.availableAreas
        
        if !searchText.isEmpty {
            areas = areas.filter { $0.localizedCaseInsensitiveContains(searchText) }
        }
        
        return areas
    }
    
    var totalCameras: Int {
        cameraManager.cameras.count
    }
    
    var onlineCameras: Int {
        cameraManager.onlineCamerasCount
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                statsHeader

                filterBar

                if cameraManager.cameras.isEmpty {
                    emptyStateView
                } else if filteredAreas.isEmpty {
                    noResultsView
                } else {
                    areasList
                }
            }
            .navigationTitle("Camera Streams")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(destination: DebugView()) {
                        Image(systemName: "ladybug.fill")
                            .foregroundColor(.orange)
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .id(refreshID)
        .onAppear {
            DebugLogger.shared.log("📹 CameraStreamsView appeared", emoji: "📹", color: .blue)
            DebugLogger.shared.log("   Cameras: \(cameraManager.cameras.count)", emoji: "📊", color: .gray)
            DebugLogger.shared.log("   Areas: \(cameraManager.availableAreas.count)", emoji: "📍", color: .gray)
            DebugLogger.shared.log("   WebSocket: \(webSocketService.isConnected ? "Connected" : "Disconnected")", emoji: webSocketService.isConnected ? "🟢" : "🔴", color: webSocketService.isConnected ? .green : .red)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CamerasUpdated"))) { _ in
            DebugLogger.shared.log("🔄 CameraStreamsView: Received CamerasUpdated notification", emoji: "🔄", color: .blue)
            refreshID = UUID()
        }
    }

    private var statsHeader: some View {
        HStack(spacing: 0) {
            StatCard(
                icon: "video.fill",
                value: "\(totalCameras)",
                label: "Total Cameras",
                color: .blue
            )
            
            Divider()
                .frame(height: 40)
            
            StatCard(
                icon: "checkmark.circle.fill",
                value: "\(onlineCameras)",
                label: "Online",
                color: .green
            )
            
            Divider()
                .frame(height: 40)
            
            StatCard(
                icon: "map.fill",
                value: "\(cameraManager.availableAreas.count)",
                label: "Areas",
                color: .purple
            )
        }
        .padding()
        .background(Color(.systemBackground))
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 2)
    }

    private var filterBar: some View {
        VStack(spacing: 12) {
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
            .padding(12)
            .background(Color(.systemGray6))
            .cornerRadius(10)
            .padding(.horizontal)

            HStack {
                Toggle(isOn: $showOnlineOnly) {
                    HStack(spacing: 8) {
                        Image(systemName: showOnlineOnly ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(showOnlineOnly ? .green : .gray)
                        Text("Show Online Only")
                            .font(.subheadline)
                    }
                }
                .toggleStyle(SwitchToggleStyle(tint: .green))
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .background(Color(.systemGroupedBackground))
    }
 
    private var areasList: some View {
        List {
            ForEach(filteredAreas, id: \.self) { area in
                NavigationLink(destination: AreaCamerasView(area: area)) {
                    AreaRow(
                        area: area,
                        cameras: getCameras(for: area)
                    )
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
    }
    
    private func getCameras(for area: String) -> [Camera] {
        let cameras = cameraManager.getCameras(forArea: area)
        
        if showOnlineOnly {
            return cameras.filter { $0.isOnline }
        }
        
        return cameras
    }
 
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 100, height: 100)
                
                Image(systemName: "video.slash")
                    .font(.system(size: 50))
                    .foregroundColor(.blue)
            }
            
            Text("No Cameras Available")
                .font(.title2)
                .fontWeight(.bold)
            
            VStack(spacing: 8) {
                Text("Camera data will appear here when available from the server")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                
                // Debug info
                Text("WebSocket: \(webSocketService.isConnected ? "Connected ✅" : "Disconnected ❌")")
                    .font(.caption)
                    .foregroundColor(webSocketService.isConnected ? .green : .red)
                
                Text("Camera Count: \(cameraManager.cameras.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            if !webSocketService.isConnected {
                Button(action: {
                    webSocketService.connect()
                }) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Reconnect")
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
    
    private var noResultsView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "magnifyingglass")
                .font(.system(size: 50))
                .foregroundColor(.gray)
            
            Text("No Results Found")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("Try adjusting your search or filters")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Button(action: {
                searchText = ""
                showOnlineOnly = false
            }) {
                Text("Clear Filters")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.blue)
                    .cornerRadius(10)
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

struct StatCard: View {
    let icon: String
    let value: String
    let label: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(color)
            
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
            
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct AreaRow: View {
    let area: String
    let cameras: [Camera]
    
    var onlineCount: Int {
        cameras.filter { $0.isOnline }.count
    }
    
    var offlineCount: Int {
        cameras.count - onlineCount
    }
    
    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.2))
                    .frame(width: 50, height: 50)
                
                Image(systemName: "map.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.blue)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(area)
                    .font(.headline)
                
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("\(onlineCount) online")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    if offlineCount > 0 {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.gray)
                                .frame(width: 8, height: 8)
                            Text("\(offlineCount) offline")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            
            Spacer()
  
            Text("\(cameras.count)")
                .font(.headline)
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(Color.blue)
                .clipShape(Circle())
        }
        .padding(.vertical, 8)
    }
}
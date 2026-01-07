import SwiftUI

// MARK: - Grid Modes
enum GridViewMode: String, CaseIterable, Identifiable {
    case list = "List"
    case grid2x2 = "2×2"
    case grid3x3 = "3×3"
    
    var id: String { rawValue }
    
    var columns: Int {
        switch self {
        case .list: return 1
        case .grid2x2: return 2
        case .grid3x3: return 3
        }
    }
    
    var icon: String {
        switch self {
        case .list: return "list.bullet"
        case .grid2x2: return "square.grid.2x2"
        case .grid3x3: return "square.grid.3x3"
        }
    }
}

// MARK: - Camera Streams Main View
struct CameraStreamsView: View {
    @StateObject private var cameraManager = CameraManager.shared
    @StateObject private var webSocketService = WebSocketService.shared
    
    @State private var searchText = ""
    @State private var showOnlineOnly = false
    @State private var selectedArea: String? = nil
    @State private var isRefreshing = false
    
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
                    HStack(spacing: 12) {
                        // Manual refresh button
                        Button(action: manualRefresh) {
                            Image(systemName: isRefreshing ? "arrow.clockwise.circle.fill" : "arrow.clockwise")
                                .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                                .animation(isRefreshing ? Animation.linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isRefreshing)
                        }
                        .disabled(isRefreshing)
                        
                        NavigationLink(destination: DebugView()) {
                            Image(systemName: "ladybug.fill")
                                .foregroundColor(.orange)
                        }
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear {
            DebugLogger.shared.log("📹 CameraStreamsView appeared", emoji: "📹", color: .blue)
        }
    }
    
    private func manualRefresh() {
        isRefreshing = true
        
        CameraAPIService.shared.fetchAllCameras { result in
            DispatchQueue.main.async {
                isRefreshing = false
                
                switch result {
                case .success(let cameras):
                    DebugLogger.shared.log("✅ Manual refresh: \(cameras.count) cameras", emoji: "✅", color: .green)
                    cameraManager.updateCameras(cameras)
                    
                case .failure(let error):
                    DebugLogger.shared.log("❌ Manual refresh failed: \(error.localizedDescription)", emoji: "❌", color: .red)
                }
            }
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
                NavigationLink(
                    destination: AreaCamerasView(area: area)
                ) {
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
                Text("Camera data will appear here when available")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                
                Text("WebSocket: \(webSocketService.isConnected ? "Connected ✅" : "Disconnected ❌")")
                    .font(.caption)
                    .foregroundColor(webSocketService.isConnected ? .green : .red)
            }
            
            Button(action: manualRefresh) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text(isRefreshing ? "Refreshing..." : "Refresh Cameras")
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.blue)
                .cornerRadius(10)
            }
            .disabled(isRefreshing)
            .padding(.top, 8)
            
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

// MARK: - Area Cameras View
struct AreaCamerasView: View {
    let area: String
    @StateObject private var cameraManager = CameraManager.shared
    @StateObject private var playerManager = HLSPlayerManager.shared
    
    @State private var searchText = ""
    @State private var showOnlineOnly = true
    @State private var gridMode: GridViewMode = .grid2x2
    @State private var selectedCamera: Camera? = nil
    
    @Environment(\.scenePhase) var scenePhase
    
    var cameras: [Camera] {
        var result = cameraManager.getCameras(forArea: area)
        if showOnlineOnly { 
            result = result.filter { $0.isOnline } 
        }
        if !searchText.isEmpty {
            result = result.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText) ||
                $0.location.localizedCaseInsensitiveContains(searchText)
            }
        }
        return result.sorted { $0.displayName < $1.displayName }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            statsBar
            filterBar
            
            if playerManager.activePlayerCount >= 2 {
                playerLimitWarning
            }
            
            cameras.isEmpty ? AnyView(emptyView) : AnyView(cameraGridView)
        }
        .navigationTitle(area)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("Layout", selection: $gridMode) {
                        ForEach(GridViewMode.allCases) { mode in
                            Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                        }
                    }
                } label: {
                    Image(systemName: gridMode.icon).font(.system(size: 18))
                }
            }
        }
        .fullScreenCover(item: $selectedCamera) { camera in
            FullscreenHLSPlayerView(camera: camera)
        }
        .onDisappear { 
            playerManager.releaseAllPlayers()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background || phase == .inactive {
                playerManager.pauseAllPlayers()
            }
        }
    }
    
    private var playerLimitWarning: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            
            Text("2 cameras playing. Close one before opening another.")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Button("Close All") {
                playerManager.releaseAllPlayers()
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.2))
            .cornerRadius(6)
        }
        .padding()
        .background(Color.orange.opacity(0.1))
    }
    
    private var statsBar: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "video.fill")
                    .foregroundColor(.blue)
                Text("\(cameras.count) camera\(cameras.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("\(cameras.filter { $0.isOnline }.count)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.gray)
                        .frame(width: 8, height: 8)
                    Text("\(cameras.filter { !$0.isOnline }.count)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .shadow(color: Color.black.opacity(0.05), radius: 2, y: 2)
    }
    
    private var filterBar: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)
                
                TextField("Search cameras...", text: $searchText)
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
    
    private var cameraGridView: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: gridMode.columns),
                spacing: 12
            ) {
                ForEach(cameras, id: \.id) { camera in
                    CameraGridCard(camera: camera, mode: gridMode)
                        .onTapGesture {
                            if camera.isOnline {
                                if playerManager.activePlayerCount >= 2 {
                                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                                } else {
                                    selectedCamera = camera
                                }
                            } else {
                                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                            }
                        }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }
    
    private var emptyView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            ZStack {
                Circle()
                    .fill(Color.gray.opacity(0.1))
                    .frame(width: 100, height: 100)
                
                Image(systemName: searchText.isEmpty ? "video.slash" : "magnifyingglass")
                    .font(.system(size: 50))
                    .foregroundColor(.gray)
            }
            
            Text(searchText.isEmpty ? "No Cameras" : "No Results")
                .font(.title2)
                .fontWeight(.bold)
            
            Text(searchText.isEmpty ? 
                 (showOnlineOnly ? "No online cameras in this area" : "No cameras found in this area") : 
                 "No cameras match your search")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - Supporting Views
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

struct CameraGridCard: View {
    let camera: Camera
    let mode: GridViewMode
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CameraThumbnailView(camera: camera, isGridView: mode != .list)
                .frame(height: height)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(camera.isOnline ? Color.blue.opacity(0.3) : Color.gray.opacity(0.3), lineWidth: 1)
                )
            
            VStack(alignment: .leading, spacing: 4) {
                Text(camera.displayName)
                    .font(titleFont)
                    .fontWeight(.medium)
                    .lineLimit(mode == .list ? 2 : 1)
                    .foregroundColor(.primary)
                
                HStack(spacing: 4) {
                    Circle()
                        .fill(camera.isOnline ? Color.green : Color.gray)
                        .frame(width: dotSize, height: dotSize)
                    
                    Text(camera.location.isEmpty ? camera.area : camera.location)
                        .font(subtitleFont)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, mode == .list ? 0 : 4)
        }
        .padding(padding)
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 5, y: 2)
        .opacity(camera.isOnline ? 1 : 0.6)
    }
    
    private var height: CGFloat {
        switch mode {
        case .list: return 140
        case .grid2x2: return 120
        case .grid3x3: return 100
        }
    }
    
    private var padding: CGFloat {
        switch mode {
        case .list: return 12
        case .grid2x2: return 10
        case .grid3x3: return 8
        }
    }
    
    private var titleFont: Font {
        switch mode {
        case .list: return .subheadline
        case .grid2x2: return .caption
        case .grid3x3: return .caption2
        }
    }
    
    private var subtitleFont: Font {
        switch mode {
        case .list: return .caption
        case .grid2x2: return .caption2
        case .grid3x3: return .system(size: 10)
        }
    }
    
    private var dotSize: CGFloat {
        switch mode {
        case .list: return 6
        case .grid2x2: return 5
        case .grid3x3: return 4
        }
    }
}
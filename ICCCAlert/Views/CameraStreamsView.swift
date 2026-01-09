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
    @State private var showMapView = false
    
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
    
    var camerasWithLocation: Int {
        cameraManager.cameras.filter { camera in
            guard let lat = Double(camera.latitude),
                  let lng = Double(camera.longitude) else {
                return false
            }
            return lat != 0 && lng != 0
        }.count
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Loading indicator
                    if cameraManager.isLoading {
                        loadingIndicatorView
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    
                    ScrollView {
                        VStack(spacing: 20) {
                            // Stats Cards
                            statsSection
                                .padding(.horizontal)
                                .padding(.top, 8)
                            
                            // Multi-View Button
                            NavigationLink(destination: MultiCameraViewsListView()) {
                                multiViewButton
                            }
                            .buttonStyle(PlainButtonStyle())
                            .padding(.horizontal)
                            
                            // Search and Filters
                            VStack(spacing: 16) {
                                searchBar
                                filterToggle
                            }
                            .padding(.horizontal)
                            
                            // Content
                            if cameraManager.cameras.isEmpty && !cameraManager.isLoading {
                                emptyStateView
                                    .padding(.top, 60)
                            } else if filteredAreas.isEmpty {
                                noResultsView
                                    .padding(.top, 60)
                            } else {
                                areasGrid
                            }
                        }
                        .padding(.bottom, 20)
                    }
                }
            }
            .navigationTitle("Camera Streams")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button(action: { 
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                showMapView = true
                            }
                        }) {
                            Image(systemName: "map.fill")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(.blue)
                        }
                        
                        Button(action: manualRefresh) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(.blue)
                                .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                                .animation(isRefreshing ? Animation.linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isRefreshing)
                        }
                        .disabled(isRefreshing || cameraManager.isLoading)
                        
                        NavigationLink(destination: DebugView()) {
                            Image(systemName: "ladybug.fill")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(.orange)
                        }
                    }
                }
            }
            .sheet(isPresented: $showMapView) {
                CameraMapView()
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear {
            DebugLogger.shared.log("📹 CameraStreamsView appeared", emoji: "📹", color: .blue)
        }
    }
    
    // MARK: - Multi-View Button
    private var multiViewButton: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [.purple.opacity(0.2), .purple.opacity(0.1)]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 50, height: 50)
                
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.purple)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Multi-Camera Views")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                
                Text("Watch up to 4 cameras at once")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.gray.opacity(0.6))
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 2)
        )
    }
    
    // MARK: - Stats Section
    private var statsSection: some View {
        HStack(spacing: 12) {
            StatCard(
                icon: "video.fill",
                value: "\(totalCameras)",
                label: "Total",
                color: .blue,
                gradient: [.blue.opacity(0.15), .blue.opacity(0.05)]
            )
            
            StatCard(
                icon: "checkmark.circle.fill",
                value: "\(onlineCameras)",
                label: "Online",
                color: .green,
                gradient: [.green.opacity(0.15), .green.opacity(0.05)]
            )
            
            StatCard(
                icon: "map.fill",
                value: "\(camerasWithLocation)",
                label: "Mapped",
                color: .purple,
                gradient: [.purple.opacity(0.15), .purple.opacity(0.05)]
            )
        }
    }
    
    // MARK: - Search Bar
    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.secondary)
            
            TextField("Search areas", text: $searchText)
                .font(.system(size: 16))
            
            if !searchText.isEmpty {
                Button(action: { 
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        searchText = ""
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.gray.opacity(0.6))
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 2)
        )
    }
    
    // MARK: - Filter Toggle
    private var filterToggle: some View {
        Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                showOnlineOnly.toggle()
            }
        }) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(showOnlineOnly ? Color.green.opacity(0.15) : Color(.systemGray5))
                        .frame(width: 32, height: 32)
                    
                    Image(systemName: showOnlineOnly ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(showOnlineOnly ? .green : .secondary)
                }
                
                Text("Show Online Only")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.primary)
                
                Spacer()
                
                if showOnlineOnly {
                    Text("\(onlineCameras)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.green.opacity(0.15))
                        )
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 2)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    // MARK: - Areas Grid
    private var areasGrid: some View {
        LazyVStack(spacing: 12) {
            ForEach(filteredAreas, id: \.self) { area in
                NavigationLink(destination: AreaCamerasView(area: area)) {
                    ModernAreaRow(
                        area: area,
                        cameras: getCameras(for: area)
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal)
    }
    
    // MARK: - Loading Indicator
    private var loadingIndicatorView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                .scaleEffect(1.2)
            
            Text("Loading cameras...")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(
            Color(.systemBackground)
                .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 2)
        )
    }
    
    // MARK: - Empty State
    private var emptyStateView: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [.blue.opacity(0.2), .blue.opacity(0.05)]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 120, height: 120)
                
                Image(systemName: "video.slash")
                    .font(.system(size: 50, weight: .light))
                    .foregroundColor(.blue)
            }
            
            VStack(spacing: 8) {
                Text("No Cameras Available")
                    .font(.system(size: 24, weight: .bold))
                
                Text("Camera data will appear here when available")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                
                HStack(spacing: 6) {
                    Circle()
                        .fill(webSocketService.isConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    
                    Text(webSocketService.isConnected ? "Connected" : "Disconnected")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(webSocketService.isConnected ? .green : .red)
                }
                .padding(.top, 4)
            }
            
            Button(action: manualRefresh) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .semibold))
                    Text(isRefreshing ? "Refreshing..." : "Refresh Cameras")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(
                    Capsule()
                        .fill(Color.blue)
                )
            }
            .disabled(isRefreshing)
            .opacity(isRefreshing ? 0.6 : 1)
        }
    }
    
    // MARK: - No Results
    private var noResultsView: some View {
        VStack(spacing: 24) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 50, weight: .light))
                .foregroundColor(.secondary)
            
            VStack(spacing: 8) {
                Text("No Results Found")
                    .font(.system(size: 24, weight: .bold))
                
                Text("Try adjusting your search or filters")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
            
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    searchText = ""
                    showOnlineOnly = false
                }
            }) {
                Text("Clear Filters")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .background(
                        Capsule()
                            .fill(Color.blue)
                    )
            }
        }
    }
    
    // MARK: - Helper Methods
    private func manualRefresh() {
        isRefreshing = true
        
        cameraManager.manualRefresh { success in
            DispatchQueue.main.async {
                withAnimation {
                    self.isRefreshing = false
                }
                
                if success {
                    DebugLogger.shared.log("✅ Manual refresh successful", emoji: "✅", color: .green)
                } else {
                    DebugLogger.shared.log("❌ Manual refresh failed", emoji: "❌", color: .red)
                }
            }
        }
    }
    
    private func getCameras(for area: String) -> [Camera] {
        let cameras = cameraManager.getCameras(forArea: area)
        
        if showOnlineOnly {
            return cameras.filter { $0.isOnline }
        }
        
        return cameras
    }
}

// MARK: - Modern Stat Card
struct StatCard: View {
    let icon: String
    let value: String
    let label: String
    let color: Color
    let gradient: [Color]
    
    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: gradient),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 56, height: 56)
                
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(color)
            }
            
            VStack(spacing: 4) {
                Text(value)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.primary)
                
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 2)
        )
    }
}

// MARK: - Modern Area Row
struct ModernAreaRow: View {
    let area: String
    let cameras: [Camera]
    
    var onlineCount: Int {
        cameras.filter { $0.isOnline }.count
    }
    
    var offlineCount: Int {
        cameras.count - onlineCount
    }
    
    var camerasWithLocation: Int {
        cameras.filter { camera in
            guard let lat = Double(camera.latitude),
                  let lng = Double(camera.longitude) else {
                return false
            }
            return lat != 0 && lng != 0
        }.count
    }
    
    var body: some View {
        HStack(spacing: 16) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [.blue.opacity(0.2), .blue.opacity(0.1)]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 60, height: 60)
                
                Image(systemName: "map.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.blue)
            }
            
            // Content
            VStack(alignment: .leading, spacing: 8) {
                Text(area)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.primary)
                
                HStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("\(onlineCount)")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    
                    if offlineCount > 0 {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.gray)
                                .frame(width: 8, height: 8)
                            Text("\(offlineCount)")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if camerasWithLocation > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "map")
                                .font(.system(size: 11, weight: .medium))
                            Text("\(camerasWithLocation)")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundColor(.purple)
                    }
                }
            }
            
            Spacer()
            
            // Total count badge
            VStack(spacing: 4) {
                Text("\(cameras.count)")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.blue)
                
                Text("total")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            
            // Chevron
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.gray.opacity(0.6))
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 2)
        )
    }
}
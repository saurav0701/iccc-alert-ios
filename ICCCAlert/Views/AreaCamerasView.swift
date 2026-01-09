import SwiftUI
import MapKit

// MARK: - Area Cameras Detail View
struct AreaCamerasView: View {
    let area: String
    @StateObject private var cameraManager = CameraManager.shared
    
    @State private var searchText = ""
    @State private var showOnlineOnly = true
    @State private var gridMode: GridViewMode = .grid2x2
    @State private var selectedCamera: Camera? = nil
    @State private var showMapView = false
    
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
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                VStack(spacing: 16) {
                    statsBar
                    searchBar
                    filterRow
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .background(
                    Color(.systemGroupedBackground)
                        .shadow(color: .black.opacity(0.03), radius: 8, x: 0, y: 2)
                )
                
                if cameras.isEmpty {
                    emptyView
                } else {
                    cameraGridView
                }
            }
        }
        .navigationTitle(area)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    if camerasWithLocation > 0 {
                        Button(action: { 
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                showMapView = true
                            }
                        }) {
                            Image(systemName: "map.fill")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(.blue)
                        }
                    }
                    
                    Menu {
                        Picker("Layout", selection: $gridMode) {
                            ForEach(GridViewMode.allCases) { mode in
                                Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                            }
                        }
                    } label: {
                        Image(systemName: gridMode.icon)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.blue)
                    }
                }
            }
        }
        .fullScreenCover(item: $selectedCamera) { camera in
            UnifiedCameraPlayerView(camera: camera)
        }
        .sheet(isPresented: $showMapView) {
            NavigationView {
                AreaCameraMapView(area: area)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") {
                                showMapView = false
                            }
                        }
                    }
            }
        }
    }
    
    // MARK: - Stats Bar
    private var statsBar: some View {
        HStack(spacing: 12) {
            StatPill(
                icon: "video.fill",
                value: "\(cameras.count)",
                color: .blue
            )
            
            Spacer()
            
            StatPill(
                icon: "circle.fill",
                value: "\(cameras.filter { $0.isOnline }.count)",
                color: .green
            )
            
            if cameras.filter({ !$0.isOnline }).count > 0 {
                StatPill(
                    icon: "circle.fill",
                    value: "\(cameras.filter { !$0.isOnline }.count)",
                    color: .gray
                )
            }
            
            if camerasWithLocation > 0 {
                StatPill(
                    icon: "map",
                    value: "\(camerasWithLocation)",
                    color: .purple
                )
            }
        }
    }
    
    // MARK: - Search Bar
    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.secondary)
            
            TextField("Search cameras", text: $searchText)
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
        )
    }
    
    // MARK: - Filter Row
    private var filterRow: some View {
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
                    Text("\(cameras.filter { $0.isOnline }.count)")
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
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    // MARK: - Camera Grid
    private var cameraGridView: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: gridMode.columns),
                spacing: 12
            ) {
                ForEach(cameras, id: \.id) { camera in
                    ModernCameraGridCard(camera: camera, mode: gridMode)
                        .onTapGesture {
                            handleCameraTap(camera)
                        }
                }
            }
            .padding()
        }
    }
    
    // MARK: - Empty View
    private var emptyView: some View {
        VStack(spacing: 24) {
            Spacer()
            
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.gray.opacity(0.2), Color.gray.opacity(0.05)]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 120, height: 120)
                
                Image(systemName: searchText.isEmpty ? "video.slash" : "magnifyingglass")
                    .font(.system(size: 50, weight: .light))
                    .foregroundColor(.gray)
            }
            
            VStack(spacing: 8) {
                Text(searchText.isEmpty ? "No Cameras" : "No Results")
                    .font(.system(size: 24, weight: .bold))
                
                Text(searchText.isEmpty ? 
                     (showOnlineOnly ? "No online cameras in this area" : "No cameras found in this area") : 
                     "No cameras match your search")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Helper Methods
    private func handleCameraTap(_ camera: Camera) {
        if !camera.isOnline {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            DebugLogger.shared.log("⚠️ Camera offline: \(camera.displayName)", emoji: "⚠️", color: .orange)
            return
        }
        
        if camera.webrtcStreamURL == nil {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            DebugLogger.shared.log("❌ No WebRTC stream for: \(camera.displayName)", emoji: "❌", color: .red)
            return
        }
        
        DebugLogger.shared.log("📹 Opening camera: \(camera.displayName)", emoji: "📹", color: .green)
        DebugLogger.shared.log("   WebRTC: \(camera.webrtcStreamURL!)", emoji: "🌐", color: .green)
        
        selectedCamera = camera
    }
}

// MARK: - Stat Pill
struct StatPill: View {
    let icon: String
    let value: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(color)
            
            Text(value)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(color.opacity(0.15))
        )
    }
}

// MARK: - Modern Camera Grid Card
struct ModernCameraGridCard: View {
    let camera: Camera
    let mode: GridViewMode
    
    var hasLocation: Bool {
        guard let lat = Double(camera.latitude),
              let lng = Double(camera.longitude) else {
            return false
        }
        return lat != 0 && lng != 0
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CameraThumbnailView(camera: camera, isGridView: mode != .list)
                .frame(height: thumbnailHeight)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            camera.isOnline ? Color.green.opacity(0.3) : Color.gray.opacity(0.2),
                            lineWidth: 2
                        )
                )
            
            VStack(alignment: .leading, spacing: 6) {
                Text(camera.displayName)
                    .font(titleFont)
                    .fontWeight(.semibold)
                    .lineLimit(mode == .list ? 2 : 1)
                    .foregroundColor(.primary)
                
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(camera.isOnline ? Color.green : Color.gray)
                            .frame(width: statusDotSize, height: statusDotSize)
                        
                        Text(camera.location.isEmpty ? camera.area : camera.location)
                            .font(subtitleFont)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    
                    Spacer()
                    
                    HStack(spacing: 6) {
                        if hasLocation {
                            Image(systemName: "map")
                                .font(.system(size: badgeSize, weight: .medium))
                                .foregroundColor(.purple)
                        }
                        
                        if camera.isOnline && camera.webrtcStreamURL != nil {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: badgeSize, weight: .medium))
                                .foregroundColor(.green)
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(cardPadding)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 2)
        )
        .opacity(camera.isOnline ? 1 : 0.5)
    }
    
    private var thumbnailHeight: CGFloat {
        switch mode {
        case .list: return 160
        case .grid2x2: return 140
        case .grid3x3: return 110
        }
    }
    
    private var cardPadding: CGFloat {
        switch mode {
        case .list: return 12
        case .grid2x2: return 10
        case .grid3x3: return 8
        }
    }
    
    private var titleFont: Font {
        switch mode {
        case .list: return .system(size: 16)
        case .grid2x2: return .system(size: 14)
        case .grid3x3: return .system(size: 12)
        }
    }
    
    private var subtitleFont: Font {
        switch mode {
        case .list: return .system(size: 13)
        case .grid2x2: return .system(size: 11)
        case .grid3x3: return .system(size: 10)
        }
    }
    
    private var statusDotSize: CGFloat {
        switch mode {
        case .list: return 7
        case .grid2x2: return 6
        case .grid3x3: return 5
        }
    }
    
    private var badgeSize: CGFloat {
        switch mode {
        case .list: return 12
        case .grid2x2: return 10
        case .grid3x3: return 9
        }
    }
}

// MARK: - Camera Thumbnail
struct CameraThumbnailView: View {
    let camera: Camera
    let isGridView: Bool
    
    var body: some View {
        ZStack {
            if camera.isOnline && camera.webrtcStreamURL != nil {
                playButtonView
            } else {
                offlineView
            }
        }
    }
    
    private var playButtonView: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [Color.green.opacity(0.25), Color.green.opacity(0.08)]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            VStack(spacing: 10) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: isGridView ? 40 : 50, weight: .light))
                    .foregroundColor(.green)
                
                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 11, weight: .medium))
                    Text("WebRTC")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.green)
            }
        }
    }
    
    private var offlineView: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [Color.gray.opacity(0.2), Color.gray.opacity(0.08)]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            VStack(spacing: 8) {
                Image(systemName: "video.slash.fill")
                    .font(.system(size: isGridView ? 30 : 36, weight: .light))
                    .foregroundColor(.gray)
                
                Text("Offline")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Area Camera Map View
struct AreaCameraMapView: View {
    let area: String
    @StateObject private var cameraManager = CameraManager.shared
    @State private var region: MKCoordinateRegion
    @State private var selectedCamera: Camera? = nil
    @State private var showOnlineOnly = true
    @State private var showFullScreenPlayer = false
    
    init(area: String) {
        self.area = area
        _region = State(initialValue: MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 23.6102, longitude: 85.2799),
            span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
        ))
    }
    
    var filteredCameras: [Camera] {
        var cameras = cameraManager.getCameras(forArea: area)
        
        if showOnlineOnly {
            cameras = cameras.filter { $0.isOnline }
        }
        
        return cameras.filter { camera in
            guard let lat = Double(camera.latitude),
                  let lng = Double(camera.longitude) else {
                return false
            }
            return lat != 0 && lng != 0
        }
    }
    
    var body: some View {
        ZStack {
            EnhancedCameraMapView(
                region: $region,
                cameras: filteredCameras,
                selectedCamera: $selectedCamera,
                mapStyle: .hybrid
            )
            .edgesIgnoringSafeArea(.all)
            
            VStack {
                HStack {
                    Spacer()
                    
                    HStack(spacing: 8) {
                        Image(systemName: "video.fill")
                            .foregroundColor(.blue)
                        Text("\(filteredCameras.count)")
                            .fontWeight(.bold)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.systemBackground).opacity(0.95))
                    .cornerRadius(20)
                    .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 2)
                }
                .padding(.horizontal)
                .padding(.top, 16)
                
                Spacer()
                
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 12, height: 12)
                            Text("Online")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        
                        if !showOnlineOnly {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color.gray)
                                    .frame(width: 12, height: 12)
                                Text("Offline")
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color(.systemBackground).opacity(0.95))
                    .cornerRadius(10)
                    .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 2)
                    
                    Spacer()
                }
                .padding()
            }
            
            if let camera = selectedCamera {
                VStack {
                    Spacer()
                    ModernCameraInfoCard(
                        camera: camera,
                        onClose: { selectedCamera = nil },
                        onView: {
                            if camera.isOnline && camera.webrtcStreamURL != nil {
                                showFullScreenPlayer = true
                            }
                        }
                    )
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .navigationTitle(area)
        .fullScreenCover(isPresented: $showFullScreenPlayer) {
            if let camera = selectedCamera {
                UnifiedCameraPlayerView(camera: camera)
            }
        }
        .onAppear {
            adjustMapToShowCameras()
        }
    }
    
    private func adjustMapToShowCameras() {
        guard !filteredCameras.isEmpty else { return }
        
        var minLat = 90.0
        var maxLat = -90.0
        var minLng = 180.0
        var maxLng = -180.0
        
        for camera in filteredCameras {
            guard let lat = Double(camera.latitude),
                  let lng = Double(camera.longitude) else {
                continue
            }
            
            minLat = min(minLat, lat)
            maxLat = max(maxLat, lat)
            minLng = min(minLng, lng)
            maxLng = max(maxLng, lng)
        }
        
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLng + maxLng) / 2
        )
        
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.5, 0.05),
            longitudeDelta: max((maxLng - minLng) * 1.5, 0.05)
        )
        
        withAnimation {
            region = MKCoordinateRegion(center: center, span: span)
        }
    }
}

import SwiftUI
import MapKit  

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
        VStack(spacing: 0) {
            statsBar
            filterBar
            
            cameras.isEmpty ? AnyView(emptyView) : AnyView(cameraGridView)
        }
        .navigationTitle(area)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 12) {
                    // Map button
                    if camerasWithLocation > 0 {
                        Button(action: { showMapView = true }) {
                            Image(systemName: "map.fill")
                                .foregroundColor(.blue)
                        }
                    }
                    
                    // Layout menu
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
    
    private var statsBar: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "video.fill")
                    .foregroundColor(.blue)
                Text("\(cameras.count) camera\(cameras.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .bold()
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
                
                if camerasWithLocation > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "map")
                            .font(.system(size: 10))
                        Text("\(camerasWithLocation)")
                            .font(.subheadline)
                            .foregroundColor(.purple)
                    }
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
                            handleCameraTap(camera)
                        }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }
    
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

// MARK: - Area Camera Map View (Filtered by Area)
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

// MARK: - Camera Grid Card
struct CameraGridCard: View {
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
        VStack(alignment: .leading, spacing: 8) {
            CameraThumbnailView(camera: camera, isGridView: mode != .list)
                .frame(height: height)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(camera.isOnline ? Color.green.opacity(0.3) : Color.gray.opacity(0.3), lineWidth: 1)
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
                    
                    Spacer()
                    
                    // Show map icon if has location
                    if hasLocation {
                        Image(systemName: "map")
                            .font(.system(size: mode == .list ? 10 : 8))
                            .foregroundColor(.purple)
                    }
                    
                    // WebRTC badge
                    if camera.isOnline && camera.webrtcStreamURL != nil {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: mode == .list ? 10 : 8))
                            .foregroundColor(.green)
                    }
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
                colors: [Color.green.opacity(0.3), Color.green.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            VStack(spacing: 8) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: isGridView ? 32 : 40))
                    .foregroundColor(.green)
                
                HStack(spacing: 4) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 10))
                    Text("WebRTC")
                        .font(.caption2)
                        .fontWeight(.medium)
                }
                .foregroundColor(.green)
            }
        }
    }
    
    private var offlineView: some View {
        ZStack {
            LinearGradient(
                colors: [Color.gray.opacity(0.3), Color.gray.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            VStack(spacing: 6) {
                Image(systemName: "video.slash.fill")
                    .font(.system(size: isGridView ? 24 : 28))
                    .foregroundColor(.gray)
                
                Text("Offline")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
    }
}
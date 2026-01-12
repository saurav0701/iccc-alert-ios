import SwiftUI
import MapKit

// MARK: - Enhanced Camera Map View with Controls

struct CameraMapViewEnhanced: View {
    @StateObject private var cameraManager = CameraManager.shared
    @Environment(\.presentationMode) var presentationMode
    
    @State private var region: MKCoordinateRegion
    @State private var selectedCamera: Camera? = nil
    @State private var showOnlineOnly = true
    @State private var selectedArea: String? = nil
    @State private var showFullScreenPlayer = false
    @State private var showFilterSheet = false
    @State private var mapStyle: MapDisplayStyle = .hybrid
    @State private var showHeatmap = false
    @State private var showClusters = true
    @State private var showMapControls = true
    @State private var searchText = ""
    @State private var isSearching = false
    
    init() {
        _region = State(initialValue: MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 23.6102, longitude: 85.2799),
            span: MKCoordinateSpan(latitudeDelta: 2.0, longitudeDelta: 2.0)
        ))
    }
    
    var filteredCameras: [Camera] {
        var cameras = cameraManager.cameras
        
        if showOnlineOnly {
            cameras = cameras.filter { $0.isOnline }
        }
        
        if let area = selectedArea {
            cameras = cameras.filter { $0.area == area }
        }
        
        if !searchText.isEmpty {
            cameras = cameras.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText) ||
                $0.area.localizedCaseInsensitiveContains(searchText) ||
                $0.location.localizedCaseInsensitiveContains(searchText)
            }
        }
        
        return cameras.filter { camera in
            guard let lat = Double(camera.latitude),
                  let lng = Double(camera.longitude) else {
                return false
            }
            return lat != 0 && lng != 0
        }
    }
    
    var availableAreas: [String] {
        Array(Set(cameraManager.cameras.map { $0.area })).sorted()
    }
    
    var body: some View {
        ZStack {
            // Map View
            EnhancedCameraMapViewV2(
                region: $region,
                cameras: filteredCameras,
                selectedCamera: $selectedCamera,
                mapStyle: mapStyle,
                showHeatmap: $showHeatmap,
                showClusters: $showClusters
            )
            .edgesIgnoringSafeArea(.all)
            
            VStack {
                // Top Bar
                topBar
                    .padding(.horizontal, 16)
                    .padding(.top, 50)
                
                // Search Bar (expandable)
                if isSearching {
                    searchBar
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                Spacer()
                
                // Bottom Controls
                VStack(spacing: 12) {
                    // Legend
                    if showMapControls {
                        legendView
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    
                    // Control Panel
                    HStack(spacing: 12) {
                        if showMapControls {
                            mapControlsPanel
                                .transition(.move(edge: .leading).combined(with: .opacity))
                        }
                        
                        Spacer()
                        
                        // Toggle controls button
                        toggleControlsButton
                    }
                }
                .padding()
            }
            
            // Camera Info Card
            if let camera = selectedCamera {
                VStack {
                    Spacer()
                    EnhancedCameraInfoCard(
                        camera: camera,
                        onClose: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                selectedCamera = nil
                            }
                        },
                        onView: {
                            if camera.isOnline && camera.webrtcStreamURL != nil {
                                showFullScreenPlayer = true
                            }
                        },
                        onNavigate: {
                            openInMaps(camera: camera)
                        }
                    )
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            
            // Quick Actions FAB
            if !isSearching && selectedCamera == nil {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        quickActionsFAB
                            .padding(.trailing, 20)
                            .padding(.bottom, 100)
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showFilterSheet) {
            filterSheet
        }
        .fullScreenCover(isPresented: $showFullScreenPlayer) {
            if let camera = selectedCamera {
                UnifiedCameraPlayerView(camera: camera)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) {
                adjustMapToShowAllCameras()
            }
        }
    }
    
    // MARK: - Top Bar
    private var topBar: some View {
        HStack(spacing: 12) {
            // Back Button
            Button(action: {
                withAnimation {
                    presentationMode.wrappedValue.dismiss()
                }
            }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        ZStack {
                            Color.black.opacity(0.3)
                            BlurView(style: .systemUltraThinMaterialDark)
                        }
                    )
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 4)
            }
            
            // Stats Badge
            HStack(spacing: 8) {
                Image(systemName: "video.fill")
                    .foregroundColor(.white)
                Text("\(filteredCameras.count)")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                
                if showOnlineOnly {
                    Divider()
                        .frame(height: 16)
                        .background(Color.white.opacity(0.5))
                    
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("Online")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                ZStack {
                    Color.black.opacity(0.4)
                    BlurView(style: .systemUltraThinMaterialDark)
                }
            )
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 4)
            
            Spacer()
            
            // Search Button
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    isSearching.toggle()
                    if !isSearching {
                        searchText = ""
                    }
                }
            }) {
                Image(systemName: isSearching ? "xmark" : "magnifyingglass")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        ZStack {
                            Color.black.opacity(0.3)
                            BlurView(style: .systemUltraThinMaterialDark)
                        }
                    )
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 4)
            }
            
            // Filter Button
            Button(action: {
                showFilterSheet = true
            }) {
                Image(systemName: selectedArea != nil ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 22))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        ZStack {
                            Color.black.opacity(0.3)
                            BlurView(style: .systemUltraThinMaterialDark)
                        }
                    )
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 4)
            }
        }
    }
    
    // MARK: - Search Bar
    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.white.opacity(0.7))
            
            TextField("Search cameras, areas...", text: $searchText)
                .foregroundColor(.white)
                .font(.system(size: 16))
                .accentColor(.white)
            
            if !searchText.isEmpty {
                Button(action: {
                    withAnimation {
                        searchText = ""
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.7))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            ZStack {
                Color.black.opacity(0.4)
                BlurView(style: .systemUltraThinMaterialDark)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 4)
    }
    
    // MARK: - Legend
    private var legendView: some View {
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
            
            if showClusters {
                HStack(spacing: 8) {
                    Image(systemName: "circle.grid.cross.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.blue)
                    Text("Clustered")
                        .font(.caption)
                        .fontWeight(.medium)
                }
            }
        }
        .padding(12)
        .background(
            ZStack {
                Color(.systemBackground).opacity(0.95)
                BlurView(style: .systemMaterial)
            }
        )
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 2)
    }
    
    // MARK: - Map Controls Panel
    private var mapControlsPanel: some View {
        VStack(spacing: 8) {
            // Map Style
            MapStyleButton(
                icon: mapStyle.icon,
                label: mapStyle.rawValue,
                isActive: true,
                action: cycleMapStyle
            )
            
            // Heatmap Toggle
            MapStyleButton(
                icon: "flame.fill",
                label: "Heat",
                isActive: showHeatmap,
                action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        showHeatmap.toggle()
                    }
                }
            )
            
            // Cluster Toggle
            MapStyleButton(
                icon: "circle.grid.cross",
                label: "Cluster",
                isActive: showClusters,
                action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        showClusters.toggle()
                    }
                }
            )
            
            // Recenter
            MapStyleButton(
                icon: "location.fill",
                label: "Center",
                isActive: false,
                action: {
                    withAnimation(.easeInOut(duration: 0.5)) {
                        adjustMapToShowAllCameras()
                    }
                }
            )
        }
        .padding(8)
        .background(
            ZStack {
                Color(.systemBackground).opacity(0.95)
                BlurView(style: .systemMaterial)
            }
        )
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 2)
    }
    
    // MARK: - Toggle Controls Button
    private var toggleControlsButton: some View {
        Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                showMapControls.toggle()
            }
        }) {
            Image(systemName: showMapControls ? "eye.slash.fill" : "eye.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.primary)
                .frame(width: 44, height: 44)
                .background(
                    ZStack {
                        Color(.systemBackground).opacity(0.95)
                        BlurView(style: .systemMaterial)
                    }
                )
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 2)
        }
    }
    
    // MARK: - Quick Actions FAB
    private var quickActionsFAB: some View {
        VStack(spacing: 12) {
            // Recenter
            FloatingActionButton(
                icon: "location.fill",
                color: .blue,
                action: {
                    withAnimation(.easeInOut(duration: 0.5)) {
                        adjustMapToShowAllCameras()
                    }
                }
            )
            
            // List View
            NavigationLink(destination: CameraStreamsView()) {
                FloatingActionButton(
                    icon: "list.bullet",
                    color: .purple,
                    action: {}
                )
            }
        }
    }
    
    // MARK: - Filter Sheet
    private var filterSheet: some View {
        NavigationView {
            List {
                Section(header: Text("Camera Status")) {
                    Toggle(isOn: $showOnlineOnly) {
                        HStack(spacing: 8) {
                            Image(systemName: showOnlineOnly ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(showOnlineOnly ? .green : .gray)
                            Text("Show Online Only")
                        }
                    }
                    .toggleStyle(SwitchToggleStyle(tint: .green))
                }
                
                Section(header: Text("Map Options")) {
                    Toggle(isOn: $showHeatmap) {
                        HStack(spacing: 8) {
                            Image(systemName: "flame.fill")
                                .foregroundColor(showHeatmap ? .orange : .gray)
                            Text("Show Heatmap")
                        }
                    }
                    .toggleStyle(SwitchToggleStyle(tint: .orange))
                    
                    Toggle(isOn: $showClusters) {
                        HStack(spacing: 8) {
                            Image(systemName: "circle.grid.cross")
                                .foregroundColor(showClusters ? .blue : .gray)
                            Text("Cluster Cameras")
                        }
                    }
                    .toggleStyle(SwitchToggleStyle(tint: .blue))
                }
                
                Section(header: Text("Map Style")) {
                    ForEach(MapDisplayStyle.allCases, id: \.self) { style in
                        Button(action: {
                            withAnimation {
                                mapStyle = style
                            }
                        }) {
                            HStack {
                                Image(systemName: style.icon)
                                    .foregroundColor(mapStyle == style ? .blue : .gray)
                                Text(style.rawValue)
                                    .foregroundColor(.primary)
                                Spacer()
                                if mapStyle == style {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }
                
                Section(header: Text("Filter by Area")) {
                    Button(action: {
                        selectedArea = nil
                        adjustMapToShowAllCameras()
                        showFilterSheet = false
                    }) {
                        HStack {
                            Text("All Areas")
                            Spacer()
                            if selectedArea == nil {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    
                    ForEach(availableAreas, id: \.self) { area in
                        Button(action: {
                            selectedArea = area
                            adjustMapToArea(area)
                            showFilterSheet = false
                        }) {
                            HStack {
                                Text(area)
                                Spacer()
                                if selectedArea == area {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                        .foregroundColor(.primary)
                    }
                }
            }
            .navigationTitle("Map Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        showFilterSheet = false
                    }
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    private func cycleMapStyle() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            let styles = MapDisplayStyle.allCases
            if let currentIndex = styles.firstIndex(of: mapStyle) {
                let nextIndex = (currentIndex + 1) % styles.count
                mapStyle = styles[nextIndex]
            }
        }
    }
    
    private func adjustMapToShowAllCameras() {
        guard !filteredCameras.isEmpty else { return }
        
        var minLat = 90.0, maxLat = -90.0
        var minLng = 180.0, maxLng = -180.0
        
        for camera in filteredCameras {
            guard let lat = Double(camera.latitude),
                  let lng = Double(camera.longitude) else { continue }
            
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
            latitudeDelta: max((maxLat - minLat) * 1.3, 0.1),
            longitudeDelta: max((maxLng - minLng) * 1.3, 0.1)
        )
        
        region = MKCoordinateRegion(center: center, span: span)
    }
    
    private func adjustMapToArea(_ area: String) {
        let areaCameras = filteredCameras.filter { $0.area == area }
        guard !areaCameras.isEmpty else { return }
        
        var minLat = 90.0, maxLat = -90.0
        var minLng = 180.0, maxLng = -180.0
        
        for camera in areaCameras {
            guard let lat = Double(camera.latitude),
                  let lng = Double(camera.longitude) else { continue }
            
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
        
        region = MKCoordinateRegion(center: center, span: span)
    }
    
    private func openInMaps(camera: Camera) {
        guard let lat = Double(camera.latitude),
              let lng = Double(camera.longitude) else { return }
        
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        mapItem.name = camera.displayName
        mapItem.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
        ])
    }
}

// MARK: - Supporting Views

struct MapStyleButton: View {
    let icon: String
    let label: String
    let isActive: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(isActive ? .blue : .secondary)
                
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(isActive ? .blue : .secondary)
            }
            .frame(width: 60, height: 50)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Color.blue.opacity(0.1) : Color.clear)
            )
        }
    }
}

struct FloatingActionButton: View {
    let icon: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 56, height: 56)
                .background(
                    ZStack {
                        Circle()
                            .fill(color)
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [color.opacity(0.8), color],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                )
                .shadow(color: color.opacity(0.4), radius: 12, x: 0, y: 6)
        }
    }
}

struct EnhancedCameraInfoCard: View {
    let camera: Camera
    let onClose: () -> Void
    let onView: () -> Void
    let onNavigate: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            ZStack {
                LinearGradient(
                    colors: camera.isOnline ?
                        [Color.green.opacity(0.8), Color.green] :
                        [Color.gray.opacity(0.8), Color.gray],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 10, height: 10)
                                .shadow(color: .white.opacity(0.8), radius: 4)
                            
                            Text(camera.isOnline ? "LIVE" : "OFFLINE")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                        }
                        
                        Text(camera.displayName)
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                    }
                    
                    Spacer()
                    
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white.opacity(0.9))
                    }
                }
                .padding()
            }
            .frame(height: 80)
            
            // Content
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    CameraInfoRow(icon: "map.fill", label: "Area", value: camera.area, color: .blue)
                    CameraInfoRow(icon: "location.fill", label: "Location", value: camera.location.isEmpty ? "Unknown" : camera.location, color: .purple)
                    
                    if camera.isOnline && camera.webrtcStreamURL != nil {
                        CameraInfoRow(icon: "antenna.radiowaves.left.and.right", label: "Stream", value: "WebRTC Available", color: .green)
                    }
                }
                
                // Actions
                HStack(spacing: 12) {
                    if camera.isOnline && camera.webrtcStreamURL != nil {
                        Button(action: onView) {
                            HStack {
                                Image(systemName: "play.circle.fill")
                                Text("View Live")
                                    .fontWeight(.semibold)
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                LinearGradient(
                                    colors: [Color.blue, Color.blue.opacity(0.8)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .cornerRadius(12)
                        }
                    }
                    
                    Button(action: onNavigate) {
                        HStack {
                            Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                            Text("Navigate")
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: camera.isOnline ? 120 : .infinity)
                        .padding(.vertical, 14)
                        .background(
                            LinearGradient(
                                colors: [Color.purple, Color.purple.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(12)
                    }
                }
            }
            .padding()
            .background(Color(.systemBackground))
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
    }
}

// MARK: - Map Display Style Extension
extension MapDisplayStyle {
    var icon: String {
        switch self {
        case .hybrid: return "map.fill"
        case .satellite: return "globe.americas.fill"
        case .standard: return "map"
        }
    }
}
import SwiftUI
import MapKit

// MARK: - Camera Map View (Performance Optimized with Default Area Filter)

struct CameraMapView: View {
    @StateObject private var cameraManager = CameraManager.shared
    @Environment(\.presentationMode) var presentationMode
    
    @State private var region: MKCoordinateRegion
    @State private var selectedCamera: Camera? = nil
    @State private var showOnlineOnly = true
    @State private var selectedArea: String? = nil // Start with first area selected
    @State private var showFullScreenPlayer = false
    @State private var showFilterSheet = false
    @State private var mapStyle: MapDisplayStyle = .hybrid
    @State private var configuration = MapConfiguration()
    @State private var showSettings = false
    
    init() {
        _region = State(initialValue: MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 23.6102, longitude: 85.2799),
            span: MKCoordinateSpan(latitudeDelta: 2.0, longitudeDelta: 2.0)
        ))
    }
    
    var availableAreas: [String] {
        Array(Set(cameraManager.cameras.map { $0.area })).sorted()
    }
    
    var filteredCameras: [Camera] {
        var cameras = cameraManager.cameras
        
        if showOnlineOnly {
            cameras = cameras.filter { $0.isOnline }
        }
        
        if let area = selectedArea {
            cameras = cameras.filter { $0.area == area }
        }
        
        return cameras.filter { camera in
            guard let lat = Double(camera.latitude),
                  let lng = Double(camera.longitude) else {
                return false
            }
            return lat != 0 && lng != 0
        }
    }
    
    var allCamerasWithValidLocation: Int {
        cameraManager.cameras.filter { camera in
            guard let lat = Double(camera.latitude),
                  let lng = Double(camera.longitude) else {
                return false
            }
            return lat != 0 && lng != 0
        }.count
    }
    
    var body: some View {
        ZStack {
            // Enhanced Map with Clustering
            EnhancedClusteredMapView(
                region: $region,
                cameras: filteredCameras,
                selectedCamera: $selectedCamera,
                mapStyle: mapStyle,
                configuration: configuration
            )
            .ignoresSafeArea()
            
            // Top Controls
            VStack {
                HStack(spacing: 12) {
                    // Back Button
                    MapControlButton(icon: "chevron.left") {
                        presentationMode.wrappedValue.dismiss()
                    }
                    
                    Spacer()
                    
                    // Stats Badge with Area Info
                    VStack(spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: "video.fill")
                                .foregroundColor(.white)
                            Text("\(filteredCameras.count)")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                        }
                        
                        if let area = selectedArea {
                            Text(area)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.9))
                        } else {
                            Text("All Areas")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.9))
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
                    .shadow(color: .black.opacity(0.3), radius: 10)
                    
                    Spacer()
                    
                    // Settings Button
                    MapControlButton(icon: "gearshape.fill") {
                        showSettings = true
                    }
                    
                    // Filter Button
                    MapControlButton(icon: selectedArea != nil ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") {
                        showFilterSheet = true
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 50)
                
                Spacer()
                
                // Enhanced Legend
                HStack {
                    enhancedLegendView
                    Spacer()
                }
                .padding()
            }
            
            // Camera Info Card
            if let camera = selectedCamera {
                VStack {
                    Spacer()
                    ModernCameraInfoCard(
                        camera: camera,
                        onClose: {
                            withAnimation(.spring()) {
                                selectedCamera = nil
                            }
                        },
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
        .navigationBarHidden(true)
        .sheet(isPresented: $showFilterSheet) {
            filterSheet
        }
        .sheet(isPresented: $showSettings) {
            mapSettingsSheet
        }
        .fullScreenCover(isPresented: $showFullScreenPlayer) {
            if let camera = selectedCamera {
                UnifiedCameraPlayerView(camera: camera)
            }
        }
        .onAppear {
            // Set first area by default for better performance
            if selectedArea == nil && !availableAreas.isEmpty {
                selectedArea = availableAreas.first
            }
            adjustMapToShowAllCameras()
        }
    }
    
    private var enhancedLegendView: some View {
        VStack(alignment: .leading, spacing: 10) {
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
            
            if configuration.showClustering {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 12, height: 12)
                    Text("Cluster")
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
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.15), radius: 10)
    }
    
    private var filterSheet: some View {
        NavigationView {
            List {
                Section(header: Text("Performance Tip")) {
                    HStack(spacing: 12) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                        Text("Filter by area for better performance with large camera counts")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
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
                
                Section(header: Text("Filter by Area")) {
                    Button(action: {
                        selectedArea = nil
                        adjustMapToShowAllCameras()
                        showFilterSheet = false
                    }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("All Areas")
                                    .font(.body)
                                Text("\(allCamerasWithValidLocation) cameras")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if selectedArea == nil {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    .foregroundColor(.primary)
                    
                    ForEach(availableAreas, id: \.self) { area in
                        Button(action: {
                            selectedArea = area
                            adjustMapToArea(area)
                            showFilterSheet = false
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(area)
                                        .font(.body)
                                    let areaCount = cameraManager.getCameras(forArea: area).filter { camera in
                                        guard let lat = Double(camera.latitude),
                                              let lng = Double(camera.longitude) else { return false }
                                        return lat != 0 && lng != 0
                                    }.count
                                    Text("\(areaCount) cameras")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
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
            .navigationTitle("Filter Cameras")
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
    
    private var mapSettingsSheet: some View {
        NavigationView {
            List {
                Section(header: Text("Map Style")) {
                    ForEach(MapDisplayStyle.allCases, id: \.self) { style in
                        Button(action: { 
                            withAnimation {
                                mapStyle = style
                            }
                        }) {
                            HStack {
                                Image(systemName: style.icon)
                                Text(style.rawValue)
                                Spacer()
                                if mapStyle == style {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                        .foregroundColor(.primary)
                    }
                }
                
                Section(header: Text("Display Options")) {
                    Toggle("Show Clustering", isOn: $configuration.showClustering)
                    Toggle("Animate Markers", isOn: $configuration.animateMarkers)
                }
                
                if configuration.showClustering {
                    Section(header: Text("Cluster Radius")) {
                        HStack {
                            Text("Radius: \(Int(configuration.clusterRadius))px")
                            Spacer()
                            Slider(value: $configuration.clusterRadius, in: 30...100, step: 10)
                                .frame(width: 150)
                        }
                    }
                }
            }
            .navigationTitle("Map Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showSettings = false }
                }
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
        
        withAnimation {
            region = MKCoordinateRegion(center: center, span: span)
        }
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
        
        withAnimation {
            region = MKCoordinateRegion(center: center, span: span)
        }
    }
}
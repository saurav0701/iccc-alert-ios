import SwiftUI
import MapKit

// MARK: - Camera Map View (Google Hybrid Tiles)

struct CameraMapView: View {
    @StateObject private var cameraManager = CameraManager.shared
    @Environment(\.presentationMode) var presentationMode
    
    @State private var region: MKCoordinateRegion
    @State private var selectedCamera: Camera? = nil
    @State private var showOnlineOnly = true
    @State private var selectedArea: String? = nil
    @State private var showFullScreenPlayer = false
    @State private var showFilterSheet = false
    @State private var mapStyle: MapDisplayStyle = .hybrid
    
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
            EnhancedCameraMapView(
                region: $region,
                cameras: filteredCameras,
                selectedCamera: $selectedCamera,
                mapStyle: mapStyle
            )
            .edgesIgnoringSafeArea(.all)
            
            // Top Controls
            VStack {
                HStack {
                    // Back Button
                    Button(action: { presentationMode.wrappedValue.dismiss() }) {
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
                    
                    Spacer()
                    
                    // Stats Badge
                    HStack(spacing: 8) {
                        Image(systemName: "video.fill")
                            .foregroundColor(.white)
                        Text("\(filteredCameras.count)")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
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
                    
                    // Filter Button
                    Button(action: { showFilterSheet = true }) {
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
                .padding(.horizontal, 20)
                .padding(.top, 50)
                
                Spacer()
                
                // Legend at Bottom
                HStack {
                    legendView
                    Spacer()
                }
                .padding()
            }
            
            // Camera Info Card (when camera selected)
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
            adjustMapToShowAllCameras()
        }
    }
    
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
        }
        .padding(12)
        .background(Color(.systemBackground).opacity(0.95))
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 2)
    }
    
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
    
    private func adjustMapToShowAllCameras() {
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
        
        var minLat = 90.0
        var maxLat = -90.0
        var minLng = 180.0
        var maxLng = -180.0
        
        for camera in areaCameras {
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
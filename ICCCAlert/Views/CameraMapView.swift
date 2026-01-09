import SwiftUI
import MapKit

// MARK: - Enhanced Camera Map View with Modern Aesthetics

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
            // ✅ Enhanced Map with Custom Styling
            EnhancedCameraMapView(
                region: $region,
                cameras: filteredCameras,
                selectedCamera: $selectedCamera,
                mapStyle: mapStyle
            )
            .edgesIgnoringSafeArea(.all)
            
            // ✅ Modern Gradient Overlay (Top)
            VStack {
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.4),
                        Color.black.opacity(0.2),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 200)
                .allowsHitTesting(false)
                
                Spacer()
            }
            
            // ✅ Modern Control Panel
            VStack(spacing: 0) {
                topControlPanel
                
                Spacer()
                
                // Bottom Controls
                if selectedCamera == nil {
                    bottomLegendPanel
                }
            }
            
            // ✅ Enhanced Camera Info Card
            if let camera = selectedCamera {
                VStack {
                    Spacer()
                    ModernCameraInfoCard(
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
                        }
                    )
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showFilterSheet) {
            modernFilterSheet
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
    
    // MARK: - Top Control Panel (Modern Design)
    
    private var topControlPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                // ✅ Glassmorphic Back Button
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
                
                // ✅ Stats Badge (Modern)
                HStack(spacing: 8) {
                    Image(systemName: "video.fill")
                        .foregroundColor(.white)
                        .font(.system(size: 14, weight: .semibold))
                    
                    Text("\(filteredCameras.count)")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                    
                    if showOnlineOnly {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
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
                
                // ✅ Filter Button
                Button(action: { showFilterSheet = true }) {
                    ZStack {
                        Image(systemName: selectedArea != nil ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                            .font(.system(size: 22))
                            .foregroundColor(.white)
                        
                        if selectedArea != nil {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 12, height: 12)
                                .offset(x: 14, y: -14)
                        }
                    }
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
            
            // ✅ Map Style Selector
            mapStylePicker
        }
    }
    
    // MARK: - Map Style Picker
    
    private var mapStylePicker: some View {
        HStack(spacing: 8) {
            ForEach(MapDisplayStyle.allCases, id: \.self) { style in
                Button(action: {
                    withAnimation(.spring(response: 0.3)) {
                        mapStyle = style
                    }
                }) {
                    Text(style.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(mapStyle == style ? .white : .white.opacity(0.7))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            ZStack {
                                if mapStyle == style {
                                    Color.blue
                                } else {
                                    Color.white.opacity(0.2)
                                }
                            }
                        )
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            ZStack {
                Color.black.opacity(0.3)
                BlurView(style: .systemUltraThinMaterialDark)
            }
        )
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 2)
        .padding(.horizontal, 20)
    }
    
    // MARK: - Bottom Legend Panel
    
    private var bottomLegendPanel: some View {
        HStack(spacing: 20) {
            // Legend
            HStack(spacing: 16) {
                LegendItem(color: .green, label: "Online", count: filteredCameras.filter { $0.isOnline }.count)
                
                if !showOnlineOnly {
                    LegendItem(color: .gray, label: "Offline", count: filteredCameras.filter { !$0.isOnline }.count)
                }
            }
            .padding(16)
            .background(
                ZStack {
                    Color.black.opacity(0.4)
                    BlurView(style: .systemUltraThinMaterialDark)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 4)
            
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 30)
    }
    
    // MARK: - Modern Filter Sheet
    
    private var modernFilterSheet: some View {
        NavigationView {
            ZStack {
                Color(.systemGroupedBackground)
                    .edgesIgnoringSafeArea(.all)
                
                ScrollView {
                    VStack(spacing: 24) {
                        // Status Filter
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Camera Status")
                                .font(.headline)
                                .foregroundColor(.primary)
                            
                            Toggle(isOn: $showOnlineOnly) {
                                HStack(spacing: 12) {
                                    Circle()
                                        .fill(showOnlineOnly ? Color.green : Color.gray)
                                        .frame(width: 12, height: 12)
                                    Text("Show Online Cameras Only")
                                        .font(.subheadline)
                                }
                            }
                            .toggleStyle(SwitchToggleStyle(tint: .green))
                            .padding()
                            .background(Color(.systemBackground))
                            .cornerRadius(12)
                        }
                        .padding(.horizontal)
                        
                        // Area Filter
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Filter by Area")
                                .font(.headline)
                                .foregroundColor(.primary)
                                .padding(.horizontal)
                            
                            VStack(spacing: 8) {
                                AreaFilterButton(
                                    title: "All Areas",
                                    isSelected: selectedArea == nil,
                                    count: cameraManager.cameras.count
                                ) {
                                    selectedArea = nil
                                    adjustMapToShowAllCameras()
                                    showFilterSheet = false
                                }
                                
                                ForEach(availableAreas, id: \.self) { area in
                                    AreaFilterButton(
                                        title: area,
                                        isSelected: selectedArea == area,
                                        count: cameraManager.getCameras(forArea: area).count
                                    ) {
                                        selectedArea = area
                                        adjustMapToArea(area)
                                        showFilterSheet = false
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                    .padding(.vertical, 20)
                }
            }
            .navigationTitle("Map Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        showFilterSheet = false
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
    
    // MARK: - Map Adjustment Functions
    
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
        
        withAnimation(.easeInOut(duration: 0.5)) {
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
        
        withAnimation(.easeInOut(duration: 0.5)) {
            region = MKCoordinateRegion(center: center, span: span)
        }
    }
}

// MARK: - Supporting Views

struct LegendItem: View {
    let color: Color
    let label: String
    let count: Int
    
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .shadow(color: color.opacity(0.5), radius: 4, x: 0, y: 2)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
    }
}

struct AreaFilterButton: View {
    let title: String
    let isSelected: Bool
    let count: Int
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                
                Spacer()
                
                Text("\(count)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.systemGray6))
                    .clipShape(Capsule())
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.blue)
                }
            }
            .padding()
            .background(isSelected ? Color.blue.opacity(0.1) : Color(.systemBackground))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
            )
        }
    }
}

// MARK: - Blur View for iOS Compatibility

struct BlurView: UIViewRepresentable {
    let style: UIBlurEffect.Style
    
    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }
    
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}

// MARK: - Map Display Style

enum MapDisplayStyle: String, CaseIterable {
    case hybrid = "Hybrid"
    case satellite = "Satellite"
    case standard = "Standard"
}
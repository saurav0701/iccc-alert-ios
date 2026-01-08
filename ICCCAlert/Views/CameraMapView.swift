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
    
    init() {
        // Jharkhand state center (default region)
        _region = State(initialValue: MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 23.6102, longitude: 85.2799),
            span: MKCoordinateSpan(latitudeDelta: 2.0, longitudeDelta: 2.0)
        ))
    }
    
    var filteredCameras: [Camera] {
        var cameras = cameraManager.cameras
        
        // Filter by online status
        if showOnlineOnly {
            cameras = cameras.filter { $0.isOnline }
        }
        
        // Filter by area if selected
        if let area = selectedArea {
            cameras = cameras.filter { $0.area == area }
        }
        
        // Only show cameras with valid coordinates
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
            CameraGoogleHybridMapView(
                region: $region,
                cameras: filteredCameras,
                selectedCamera: $selectedCamera
            )
            .edgesIgnoringSafeArea(.all)
            
            // Top Controls
            VStack {
                HStack {
                    // Back Button
                    Button(action: { presentationMode.wrappedValue.dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.primary)
                            .frame(width: 44, height: 44)
                            .background(Color(.systemBackground))
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
                    }
                    
                    Spacer()
                    
                    // Stats Badge
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
                    
                    Spacer()
                    
                    // Filter Button
                    Button(action: { showFilterSheet = true }) {
                        Image(systemName: selectedArea != nil ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                            .font(.system(size: 22))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(selectedArea != nil ? Color.green : Color.blue)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
                    }
                }
                .padding(.horizontal)
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
                    CameraInfoCard(
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

// MARK: - Camera Info Card

struct CameraInfoCard: View {
    let camera: Camera
    let onClose: () -> Void
    let onView: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(camera.displayName)
                        .font(.headline)
                        .fontWeight(.bold)
                    
                    HStack(spacing: 4) {
                        Circle()
                            .fill(camera.isOnline ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(camera.isOnline ? "Online" : "Offline")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.gray)
                }
            }
            
            Divider()
            
            // Details
            VStack(alignment: .leading, spacing: 12) {
                InfoRowCompact(icon: "map.fill", label: "Area", value: camera.area)
                InfoRowCompact(icon: "location.fill", label: "Location", value: camera.location.isEmpty ? "Unknown" : camera.location)
                
                if camera.isOnline && camera.webrtcStreamURL != nil {
                    InfoRowCompact(icon: "antenna.radiowaves.left.and.right", label: "Stream", value: "WebRTC Available")
                        .foregroundColor(.green)
                }
            }
            
            // Action Button
            if camera.isOnline && camera.webrtcStreamURL != nil {
                Button(action: onView) {
                    HStack {
                        Image(systemName: "play.circle.fill")
                        Text("View Live Stream")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.blue)
                    .cornerRadius(12)
                }
            } else {
                HStack {
                    Image(systemName: "video.slash.fill")
                    Text(camera.isOnline ? "Stream Unavailable" : "Camera Offline")
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(.systemGray6))
                .cornerRadius(12)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
    }
}

struct InfoRowCompact: View {
    let icon: String
    let label: String
    let value: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 20)
            
            Text("\(label):")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
            
            Spacer()
        }
    }
}

// MARK: - Camera Google Hybrid Map View

struct CameraGoogleHybridMapView: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    let cameras: [Camera]
    @Binding var selectedCamera: Camera?
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        
        // Use Google Hybrid tile overlay (same as GPS events)
        let overlay = GoogleHybridTileOverlay()
        overlay.canReplaceMapContent = true
        mapView.addOverlay(overlay, level: .aboveLabels)
        
        return mapView
    }
    
    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Update region
        mapView.setRegion(region, animated: true)
        
        // Remove old annotations
        mapView.removeAnnotations(mapView.annotations)
        
        // Add camera annotations
        for camera in cameras {
            guard let lat = Double(camera.latitude),
                  let lng = Double(camera.longitude),
                  lat != 0, lng != 0 else {
                continue
            }
            
            let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            let annotation = CameraMapAnnotation(
                coordinate: coordinate,
                camera: camera
            )
            mapView.addAnnotation(annotation)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: CameraGoogleHybridMapView
        
        init(_ parent: CameraGoogleHybridMapView) {
            self.parent = parent
        }
        
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let cameraAnnotation = annotation as? CameraMapAnnotation else { return nil }
            
            let identifier = "CameraPin"
            var annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
            
            if annotationView == nil {
                annotationView = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                annotationView?.canShowCallout = false // We use custom card
            } else {
                annotationView?.annotation = annotation
            }
            
            // Custom camera icon
            let size = CGSize(width: 40, height: 40)
            let renderer = UIGraphicsImageRenderer(size: size)
            
            let image = renderer.image { ctx in
                // Background circle
                let bgColor = cameraAnnotation.camera.isOnline ? UIColor.systemGreen : UIColor.systemGray
                bgColor.setFill()
                
                let bgRect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
                ctx.cgContext.fillEllipse(in: bgRect)
                
                // White border
                UIColor.white.setStroke()
                ctx.cgContext.setLineWidth(3)
                ctx.cgContext.strokeEllipse(in: bgRect)
                
                // Camera icon
                let iconSize: CGFloat = 20
                let iconRect = CGRect(
                    x: (size.width - iconSize) / 2,
                    y: (size.height - iconSize) / 2,
                    width: iconSize,
                    height: iconSize
                )
                
                if let cameraIcon = UIImage(systemName: "video.fill")?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                    cameraIcon.draw(in: iconRect)
                }
            }
            
            annotationView?.image = image
            annotationView?.centerOffset = CGPoint(x: 0, y: -size.height / 2)
            
            return annotationView
        }
        
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let cameraAnnotation = view.annotation as? CameraMapAnnotation else { return }
            
            DispatchQueue.main.async {
                withAnimation {
                    self.parent.selectedCamera = cameraAnnotation.camera
                }
            }
            
            // Deselect to allow re-selection
            mapView.deselectAnnotation(view.annotation, animated: false)
        }
        
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tileOverlay)
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

// MARK: - Camera Map Annotation

class CameraMapAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let camera: Camera
    
    var title: String? {
        return camera.displayName
    }
    
    var subtitle: String? {
        return camera.area
    }
    
    init(coordinate: CLLocationCoordinate2D, camera: Camera) {
        self.coordinate = coordinate
        self.camera = camera
    }
}
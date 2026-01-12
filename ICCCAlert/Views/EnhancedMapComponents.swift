import SwiftUI
import MapKit

// MARK: - Enhanced Map Configuration
struct MapConfiguration {
    var showClustering: Bool = true
    var showHeatmap: Bool = false
    var animateMarkers: Bool = true
    var showTraffic: Bool = false
    var clusterRadius: Double = 50 // pixels
}

// MARK: - Camera Cluster Annotation
class CameraClusterAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let cameras: [Camera]
    
    var title: String? {
        return "\(cameras.count) cameras"
    }
    
    var subtitle: String? {
        let online = cameras.filter { $0.isOnline }.count
        return "\(online) online"
    }
    
    init(coordinate: CLLocationCoordinate2D, cameras: [Camera]) {
        self.coordinate = coordinate
        self.cameras = cameras
    }
}

// MARK: - Enhanced Map View with Clustering
struct EnhancedClusteredMapView: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    let cameras: [Camera]
    @Binding var selectedCamera: Camera?
    let mapStyle: MapDisplayStyle
    let configuration: MapConfiguration
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        
        // Enable all gestures
        mapView.isZoomEnabled = true
        mapView.isScrollEnabled = true
        mapView.isRotateEnabled = true
        mapView.isPitchEnabled = true
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.showsUserLocation = false
        
        // Register custom annotation views
        mapView.register(
            ClusterAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier
        )
        
        applyMapStyle(mapView, style: mapStyle)
        
        return mapView
    }
    
    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Update region smoothly
        if abs(mapView.region.center.latitude - region.center.latitude) > 0.001 ||
           abs(mapView.region.center.longitude - region.center.longitude) > 0.001 {
            mapView.setRegion(region, animated: true)
        }
        
        applyMapStyle(mapView, style: mapStyle)
        context.coordinator.configuration = configuration
        
        // Update annotations with clustering
        updateAnnotations(mapView, context: context)
    }
    
    private func updateAnnotations(_ mapView: MKMapView, context: Context) {
        let existingAnnotations = mapView.annotations.filter { !($0 is MKUserLocation) }
        mapView.removeAnnotations(existingAnnotations)
        
        if configuration.showClustering && mapView.camera.centerCoordinateDistance > 50000 {
            // Use clustering for zoomed out view
            let clusters = clusterCameras(cameras, mapView: mapView)
            
            for cluster in clusters {
                if cluster.cameras.count == 1 {
                    // Single camera - show individual annotation
                    let camera = cluster.cameras[0]
                    guard let lat = Double(camera.latitude),
                          let lng = Double(camera.longitude),
                          lat != 0, lng != 0 else { continue }
                    
                    let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
                    let annotation = EnhancedCameraAnnotation(coordinate: coordinate, camera: camera)
                    mapView.addAnnotation(annotation)
                } else {
                    // Multiple cameras - show cluster
                    mapView.addAnnotation(cluster)
                }
            }
        } else {
            // Show individual cameras
            for camera in cameras {
                guard let lat = Double(camera.latitude),
                      let lng = Double(camera.longitude),
                      lat != 0, lng != 0 else { continue }
                
                let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
                let annotation = EnhancedCameraAnnotation(coordinate: coordinate, camera: camera)
                mapView.addAnnotation(annotation)
            }
        }
    }
    
    private func clusterCameras(_ cameras: [Camera], mapView: MKMapView) -> [CameraClusterAnnotation] {
        var clusters: [CameraClusterAnnotation] = []
        var processedCameras: Set<String> = []
        
        let screenRect = mapView.bounds
        let radiusInPoints = configuration.clusterRadius
        
        for camera in cameras {
            guard !processedCameras.contains(camera.id),
                  let lat = Double(camera.latitude),
                  let lng = Double(camera.longitude),
                  lat != 0, lng != 0 else { continue }
            
            let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            let point = mapView.convert(coordinate, toPointTo: mapView)
            
            // Find nearby cameras
            var clusterCameras: [Camera] = [camera]
            processedCameras.insert(camera.id)
            
            for otherCamera in cameras {
                guard !processedCameras.contains(otherCamera.id),
                      let otherLat = Double(otherCamera.latitude),
                      let otherLng = Double(otherCamera.longitude),
                      otherLat != 0, otherLng != 0 else { continue }
                
                let otherCoordinate = CLLocationCoordinate2D(latitude: otherLat, longitude: otherLng)
                let otherPoint = mapView.convert(otherCoordinate, toPointTo: mapView)
                
                let distance = hypot(point.x - otherPoint.x, point.y - otherPoint.y)
                
                if distance < radiusInPoints {
                    clusterCameras.append(otherCamera)
                    processedCameras.insert(otherCamera.id)
                }
            }
            
            // Calculate cluster center
            let avgLat = clusterCameras.compactMap { Double($0.latitude) }.reduce(0, +) / Double(clusterCameras.count)
            let avgLng = clusterCameras.compactMap { Double($0.longitude) }.reduce(0, +) / Double(clusterCameras.count)
            let clusterCoord = CLLocationCoordinate2D(latitude: avgLat, longitude: avgLng)
            
            clusters.append(CameraClusterAnnotation(coordinate: clusterCoord, cameras: clusterCameras))
        }
        
        return clusters
    }
    
    private func applyMapStyle(_ mapView: MKMapView, style: MapDisplayStyle) {
        mapView.removeOverlays(mapView.overlays)
        
        switch style {
        case .hybrid:
            let overlay = GoogleHybridTileOverlay()
            overlay.canReplaceMapContent = true
            mapView.addOverlay(overlay, level: .aboveLabels)
        case .satellite:
            let overlay = GoogleSatelliteTileOverlay()
            overlay.canReplaceMapContent = true
            mapView.addOverlay(overlay, level: .aboveLabels)
        case .standard:
            break
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: EnhancedClusteredMapView
        var configuration: MapConfiguration
        private var animationTimer: Timer?
        
        init(_ parent: EnhancedClusteredMapView) {
            self.parent = parent
            self.configuration = parent.configuration
        }
        
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            // Handle cluster annotations
            if let cluster = annotation as? CameraClusterAnnotation {
                let identifier = "ClusterAnnotation"
                var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? ClusterAnnotationView
                
                if view == nil {
                    view = ClusterAnnotationView(annotation: cluster, reuseIdentifier: identifier)
                } else {
                    view?.annotation = cluster
                }
                
                view?.updateCount(cluster.cameras.count)
                view?.updateOnlineStatus(cluster.cameras.filter { $0.isOnline }.count)
                
                return view
            }
            
            // Handle individual camera annotations
            if let cameraAnnotation = annotation as? EnhancedCameraAnnotation {
                let identifier = "EnhancedCameraPin"
                var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                
                if view == nil {
                    view = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                    view?.canShowCallout = false
                } else {
                    view?.annotation = annotation
                }
                
                let camera = cameraAnnotation.camera
                let size = CGSize(width: 50, height: 50)
                let image = createEnhancedMarker(camera: camera, size: size)
                
                view?.image = image
                view?.centerOffset = CGPoint(x: 0, y: -size.height / 2)
                
                // Animate marker on appear
                if configuration.animateMarkers {
                    view?.alpha = 0
                    view?.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
                    UIView.animate(
                        withDuration: 0.4,
                        delay: 0,
                        usingSpringWithDamping: 0.6,
                        initialSpringVelocity: 0.5
                    ) {
                        view?.alpha = 1
                        view?.transform = .identity
                    }
                }
                
                // Pulse animation for online cameras
                if camera.isOnline && configuration.animateMarkers {
                    startPulseAnimation(view: view)
                }
                
                return view
            }
            
            return nil
        }
        
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            // Handle cluster selection
            if let cluster = view.annotation as? CameraClusterAnnotation {
                if cluster.cameras.count > 1 {
                    // Zoom into cluster
                    zoomToCluster(cluster, mapView: mapView)
                    mapView.deselectAnnotation(view.annotation, animated: false)
                } else if let camera = cluster.cameras.first {
                    selectCamera(camera, view: view, mapView: mapView)
                }
                return
            }
            
            // Handle individual camera selection
            if let cameraAnnotation = view.annotation as? EnhancedCameraAnnotation {
                selectCamera(cameraAnnotation.camera, view: view, mapView: mapView)
            }
        }
        
        private func selectCamera(_ camera: Camera, view: MKAnnotationView, mapView: MKMapView) {
            UIView.animate(
                withDuration: 0.3,
                delay: 0,
                usingSpringWithDamping: 0.6,
                initialSpringVelocity: 0.5
            ) {
                view.transform = CGAffineTransform(scaleX: 1.3, y: 1.3)
            }
            
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    self.parent.selectedCamera = camera
                }
            }
            
            mapView.deselectAnnotation(view.annotation, animated: false)
        }
        
        private func zoomToCluster(_ cluster: CameraClusterAnnotation, mapView: MKMapView) {
            let cameras = cluster.cameras
            guard cameras.count > 1 else { return }
            
            var minLat = 90.0
            var maxLat = -90.0
            var minLng = 180.0
            var maxLng = -180.0
            
            for camera in cameras {
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
                latitudeDelta: max((maxLat - minLat) * 1.5, 0.01),
                longitudeDelta: max((maxLng - minLng) * 1.5, 0.01)
            )
            
            let region = MKCoordinateRegion(center: center, span: span)
            mapView.setRegion(region, animated: true)
        }
        
        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            UIView.animate(withDuration: 0.2) {
                view.transform = .identity
            }
        }
        
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // Re-cluster when zoom level changes significantly
            if configuration.showClustering {
                parent.updateAnnotations(mapView, context: Context(coordinator: self))
            }
        }
        
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tileOverlay)
            }
            return MKOverlayRenderer(overlay: overlay)
        }
        
        private func startPulseAnimation(view: MKAnnotationView?) {
            guard let view = view else { return }
            
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.duration = 1.5
            pulse.fromValue = 1.0
            pulse.toValue = 0.3
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            
            view.layer.add(pulse, forKey: "pulse")
        }
        
        private func createEnhancedMarker(camera: Camera, size: CGSize) -> UIImage {
            let renderer = UIGraphicsImageRenderer(size: size)
            
            return renderer.image { ctx in
                // Shadow
                ctx.cgContext.setShadow(
                    offset: CGSize(width: 0, height: 3),
                    blur: 10,
                    color: UIColor.black.withAlphaComponent(0.5).cgColor
                )
                
                let outerCircle = CGRect(x: 2, y: 2, width: size.width - 4, height: size.height - 4)
                
                // Gradient background
                let gradient: CGGradient
                if camera.isOnline {
                    let colors = [
                        UIColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 1.0).cgColor,
                        UIColor(red: 0.1, green: 0.6, blue: 0.3, alpha: 1.0).cgColor
                    ]
                    gradient = CGGradient(
                        colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: colors as CFArray,
                        locations: [0, 1]
                    )!
                } else {
                    let colors = [
                        UIColor.systemGray.cgColor,
                        UIColor.systemGray.darker().cgColor
                    ]
                    gradient = CGGradient(
                        colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: colors as CFArray,
                        locations: [0, 1]
                    )!
                }
                
                ctx.cgContext.saveGState()
                ctx.cgContext.addEllipse(in: outerCircle)
                ctx.cgContext.clip()
                ctx.cgContext.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: outerCircle.midX, y: outerCircle.minY),
                    end: CGPoint(x: outerCircle.midX, y: outerCircle.maxY),
                    options: []
                )
                ctx.cgContext.restoreGState()
                
                // White border
                UIColor.white.setStroke()
                ctx.cgContext.setLineWidth(3)
                ctx.cgContext.strokeEllipse(in: outerCircle)
                
                // Inner circle
                let innerCircle = CGRect(x: 10, y: 10, width: size.width - 20, height: size.height - 20)
                UIColor.white.setFill()
                ctx.cgContext.fillEllipse(in: innerCircle)
                
                // Camera icon
                let iconSize: CGFloat = 20
                let iconRect = CGRect(
                    x: (size.width - iconSize) / 2,
                    y: (size.height - iconSize) / 2,
                    width: iconSize,
                    height: iconSize
                )
                
                let iconColor = camera.isOnline ? UIColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 1.0) : UIColor.systemGray
                if let icon = UIImage(systemName: "video.fill")?.withTintColor(iconColor, renderingMode: .alwaysOriginal) {
                    icon.draw(in: iconRect)
                }
                
                // Online indicator
                if camera.isOnline {
                    let indicatorCircle = CGRect(x: 32, y: 2, width: 16, height: 16)
                    UIColor.white.setFill()
                    ctx.cgContext.fillEllipse(in: indicatorCircle)
                    
                    UIColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 1.0).setFill()
                    let innerIndicator = indicatorCircle.insetBy(dx: 2, dy: 2)
                    ctx.cgContext.fillEllipse(in: innerIndicator)
                }
            }
        }
    }
}

// MARK: - Cluster Annotation View
class ClusterAnnotationView: MKAnnotationView {
    private let countLabel = UILabel()
    private let onlineIndicator = UIView()
    
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        setupView()
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupView() {
        frame = CGRect(x: 0, y: 0, width: 60, height: 60)
        centerOffset = CGPoint(x: 0, y: -30)
        
        // Main circle with gradient
        let gradientLayer = CAGradientLayer()
        gradientLayer.frame = bounds
        gradientLayer.colors = [
            UIColor.systemBlue.cgColor,
            UIColor.systemBlue.darker().cgColor
        ]
        gradientLayer.cornerRadius = 30
        layer.insertSublayer(gradientLayer, at: 0)
        
        // Shadow
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 3)
        layer.shadowRadius = 10
        layer.shadowOpacity = 0.5
        
        // White border
        layer.borderColor = UIColor.white.cgColor
        layer.borderWidth = 3
        layer.cornerRadius = 30
        
        // Count label
        countLabel.textAlignment = .center
        countLabel.font = UIFont.systemFont(ofSize: 20, weight: .bold)
        countLabel.textColor = .white
        countLabel.frame = CGRect(x: 0, y: 15, width: 60, height: 30)
        addSubview(countLabel)
        
        // Online indicator
        onlineIndicator.frame = CGRect(x: 42, y: 2, width: 16, height: 16)
        onlineIndicator.backgroundColor = .systemGreen
        onlineIndicator.layer.cornerRadius = 8
        onlineIndicator.layer.borderWidth = 2
        onlineIndicator.layer.borderColor = UIColor.white.cgColor
        addSubview(onlineIndicator)
    }
    
    func updateCount(_ count: Int) {
        countLabel.text = "\(count)"
    }
    
    func updateOnlineStatus(_ onlineCount: Int) {
        onlineIndicator.isHidden = onlineCount == 0
    }
}

// MARK: - Enhanced Camera Map View (Main Interface)
struct SuperEnhancedCameraMapView: View {
    @StateObject private var cameraManager = CameraManager.shared
    @Environment(\.presentationMode) var presentationMode
    
    @State private var region: MKCoordinateRegion
    @State private var selectedCamera: Camera? = nil
    @State private var showOnlineOnly = true
    @State private var selectedArea: String? = nil
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
                Section(header: Text("Camera Status")) {
                    Toggle(isOn: $showOnlineOnly) {
                        HStack(spacing: 8) {
                            Image(systemName: showOnlineOnly ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(showOnlineOnly ? .green : .gray)
                            Text("Show Online Only")
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
                    
                    ForEach(Array(Set(cameraManager.cameras.map { $0.area })).sorted(), id: \.self) { area in
                        Button(action: {
                            selectedArea = area
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
                    Button("Done") { showFilterSheet = false }
                }
            }
        }
    }
    
    private var mapSettingsSheet: some View {
        NavigationView {
            List {
                Section(header: Text("Map Style")) {
                    ForEach(MapDisplayStyle.allCases, id: \.self) { style in
                        Button(action: { mapStyle = style }) {
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
}

// MARK: - Map Control Button
struct MapControlButton: View {
    let icon: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
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
    }
}
import SwiftUI
import MapKit

// MARK: - Map Display Style
enum MapDisplayStyle: String, CaseIterable {
    case hybrid = "Hybrid"
    case satellite = "Satellite"
    case standard = "Standard"
    
    var icon: String {
        switch self {
        case .hybrid: return "map.fill"
        case .satellite: return "globe.americas.fill"
        case .standard: return "map"
        }
    }
}

// MARK: - Google Tile Overlays
class GoogleHybridTileOverlay: MKTileOverlay {
    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        let urlString = "https://mt1.google.com/vt/lyrs=y&x=\(path.x)&y=\(path.y)&z=\(path.z)"
        return URL(string: urlString)!
    }
}

class GoogleSatelliteTileOverlay: MKTileOverlay {
    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        let urlString = "https://mt1.google.com/vt/lyrs=s&x=\(path.x)&y=\(path.y)&z=\(path.z)"
        return URL(string: urlString)!
    }
}

// MARK: - Blur View
struct BlurView: UIViewRepresentable {
    let style: UIBlurEffect.Style
    
    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }
    
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}

// MARK: - UIColor Extension
extension UIColor {
    func darker(by percentage: CGFloat = 0.2) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        self.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return UIColor(hue: h, saturation: s, brightness: max(b * (1 - percentage), 0), alpha: a)
    }
}

// MARK: - Enhanced Camera Annotation
class EnhancedCameraAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let camera: Camera
    
    var title: String? {
        return camera.displayName
    }
    
    var subtitle: String? {
        return "\(camera.area) • \(camera.isOnline ? "Online" : "Offline")"
    }
    
    init(coordinate: CLLocationCoordinate2D, camera: Camera) {
        self.coordinate = coordinate
        self.camera = camera
    }
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

// MARK: - Map Configuration
struct MapConfiguration {
    var showClustering: Bool = true
    var showHeatmap: Bool = false
    var animateMarkers: Bool = true
    var showTraffic: Bool = false
    var clusterRadius: Double = 50
}

// MARK: - Enhanced Clustered Map View
struct EnhancedClusteredMapView: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    let cameras: [Camera]
    @Binding var selectedCamera: Camera?
    let mapStyle: MapDisplayStyle
    let configuration: MapConfiguration
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        
        mapView.isZoomEnabled = true
        mapView.isScrollEnabled = true
        mapView.isRotateEnabled = true
        mapView.isPitchEnabled = true
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.showsUserLocation = false
        
        applyMapStyle(mapView, style: mapStyle)
        
        return mapView
    }
    
    func updateUIView(_ mapView: MKMapView, context: Context) {
        if abs(mapView.region.center.latitude - region.center.latitude) > 0.001 ||
           abs(mapView.region.center.longitude - region.center.longitude) > 0.001 {
            mapView.setRegion(region, animated: true)
        }
        
        applyMapStyle(mapView, style: mapStyle)
        context.coordinator.configuration = configuration
        updateAnnotations(mapView, context: context)
    }
    
    private func updateAnnotations(_ mapView: MKMapView, context: Context) {
        let existingAnnotations = mapView.annotations.filter { !($0 is MKUserLocation) }
        mapView.removeAnnotations(existingAnnotations)
        
        if configuration.showClustering && mapView.camera.centerCoordinateDistance > 50000 {
            let clusters = clusterCameras(cameras, mapView: mapView)
            
            for cluster in clusters {
                if cluster.cameras.count == 1 {
                    let camera = cluster.cameras[0]
                    guard let lat = Double(camera.latitude),
                          let lng = Double(camera.longitude),
                          lat != 0, lng != 0 else { continue }
                    
                    let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
                    let annotation = EnhancedCameraAnnotation(coordinate: coordinate, camera: camera)
                    mapView.addAnnotation(annotation)
                } else {
                    mapView.addAnnotation(cluster)
                }
            }
        } else {
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
        
        let radiusInPoints = configuration.clusterRadius
        
        for camera in cameras {
            guard !processedCameras.contains(camera.id),
                  let lat = Double(camera.latitude),
                  let lng = Double(camera.longitude),
                  lat != 0, lng != 0 else { continue }
            
            let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            let point = mapView.convert(coordinate, toPointTo: mapView)
            
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
        
        init(_ parent: EnhancedClusteredMapView) {
            self.parent = parent
            self.configuration = parent.configuration
        }
        
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
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
                
                if camera.isOnline && configuration.animateMarkers {
                    startPulseAnimation(view: view)
                }
                
                return view
            }
            
            return nil
        }
        
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let cluster = view.annotation as? CameraClusterAnnotation {
                if cluster.cameras.count > 1 {
                    zoomToCluster(cluster, mapView: mapView)
                    mapView.deselectAnnotation(view.annotation, animated: false)
                } else if let camera = cluster.cameras.first {
                    selectCamera(camera, view: view, mapView: mapView)
                }
                return
            }
            
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
            
            var minLat = 90.0, maxLat = -90.0
            var minLng = 180.0, maxLng = -180.0
            
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
                ctx.cgContext.setShadow(
                    offset: CGSize(width: 0, height: 3),
                    blur: 10,
                    color: UIColor.black.withAlphaComponent(0.5).cgColor
                )
                
                let outerCircle = CGRect(x: 2, y: 2, width: size.width - 4, height: size.height - 4)
                
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
                
                UIColor.white.setStroke()
                ctx.cgContext.setLineWidth(3)
                ctx.cgContext.strokeEllipse(in: outerCircle)
                
                let innerCircle = CGRect(x: 10, y: 10, width: size.width - 20, height: size.height - 20)
                UIColor.white.setFill()
                ctx.cgContext.fillEllipse(in: innerCircle)
                
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
        
        let gradientLayer = CAGradientLayer()
        gradientLayer.frame = bounds
        gradientLayer.colors = [
            UIColor.systemBlue.cgColor,
            UIColor.systemBlue.darker().cgColor
        ]
        gradientLayer.cornerRadius = 30
        layer.insertSublayer(gradientLayer, at: 0)
        
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 3)
        layer.shadowRadius = 10
        layer.shadowOpacity = 0.5
        
        layer.borderColor = UIColor.white.cgColor
        layer.borderWidth = 3
        layer.cornerRadius = 30
        
        countLabel.textAlignment = .center
        countLabel.font = UIFont.systemFont(ofSize: 20, weight: .bold)
        countLabel.textColor = .white
        countLabel.frame = CGRect(x: 0, y: 15, width: 60, height: 30)
        addSubview(countLabel)
        
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

// MARK: - Modern Camera Info Card
struct ModernCameraInfoCard: View {
    let camera: Camera
    let onClose: () -> Void
    let onView: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
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
            
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    CameraInfoRow(icon: "map.fill", label: "Area", value: camera.area, color: .blue)
                    CameraInfoRow(icon: "location.fill", label: "Location", value: camera.location.isEmpty ? "Unknown" : camera.location, color: .purple)
                    
                    if camera.isOnline && camera.webrtcStreamURL != nil {
                        CameraInfoRow(icon: "antenna.radiowaves.left.and.right", label: "Stream", value: "WebRTC Available", color: .green)
                    }
                }
                
                if camera.isOnline && camera.webrtcStreamURL != nil {
                    Button(action: onView) {
                        HStack {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 20))
                            Text("View Live Stream")
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
                        .shadow(color: .blue.opacity(0.3), radius: 8, x: 0, y: 4)
                    }
                } else {
                    HStack {
                        Image(systemName: "video.slash.fill")
                        Text(camera.isOnline ? "Stream Unavailable" : "Camera Offline")
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                }
            }
            .padding()
            .background(Color(.systemBackground))
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
    }
}

// MARK: - Camera Info Row
struct CameraInfoRow: View {
    let icon: String
    let label: String
    let value: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 36, height: 36)
                
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(color)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text(value)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
            }
            
            Spacer()
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
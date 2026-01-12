import SwiftUI
import MapKit

// MARK: - Enhanced Camera Map View with Clustering & Heatmap

struct EnhancedCameraMapViewV2: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    let cameras: [Camera]
    @Binding var selectedCamera: Camera?
    let mapStyle: MapDisplayStyle
    @Binding var showHeatmap: Bool
    @Binding var showClusters: Bool
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        
        // Enable smooth interactions
        mapView.isZoomEnabled = true
        mapView.isScrollEnabled = true
        mapView.isRotateEnabled = true
        mapView.isPitchEnabled = true
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.showsUserLocation = true
        
        // Enable clustering
        mapView.register(
            MKMarkerAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: MKMapViewDefaultAnnotationViewReuseIdentifier
        )
        
        applyMapStyle(mapView, style: mapStyle)
        
        return mapView
    }
    
    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        
        // Smooth region update
        if !context.coordinator.isUserInteracting {
            mapView.setRegion(region, animated: true)
        }
        
        applyMapStyle(mapView, style: mapStyle)
        
        // Update annotations
        let currentAnnotations = mapView.annotations.compactMap { $0 as? CameraAnnotation }
        let currentIDs = Set(currentAnnotations.map { $0.camera.id })
        let newIDs = Set(cameras.map { $0.id })
        
        // Remove annotations no longer needed
        let toRemove = currentAnnotations.filter { !newIDs.contains($0.camera.id) }
        mapView.removeAnnotations(toRemove)
        
        // Add new annotations
        let toAdd = cameras.filter { camera in
            guard !currentIDs.contains(camera.id),
                  let lat = Double(camera.latitude),
                  let lng = Double(camera.longitude),
                  lat != 0, lng != 0 else {
                return false
            }
            return true
        }
        
        for camera in toAdd {
            guard let lat = Double(camera.latitude),
                  let lng = Double(camera.longitude) else { continue }
            
            let annotation = CameraAnnotation(
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                camera: camera
            )
            mapView.addAnnotation(annotation)
        }
        
        // Update heatmap overlay
        if showHeatmap {
            context.coordinator.updateHeatmap(mapView: mapView, cameras: cameras)
        } else {
            context.coordinator.removeHeatmap(mapView: mapView)
        }
    }
    
    private func applyMapStyle(_ mapView: MKMapView, style: MapDisplayStyle) {
        let existingOverlays = mapView.overlays.filter { !($0 is HeatmapOverlay) }
        mapView.removeOverlays(existingOverlays)
        
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
        var parent: EnhancedCameraMapViewV2
        var isUserInteracting = false
        private var heatmapOverlay: HeatmapOverlay?
        
        init(_ parent: EnhancedCameraMapViewV2) {
            self.parent = parent
        }
        
        // MARK: - Clustering Support
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let cameraAnnotation = annotation as? CameraAnnotation else {
                return nil
            }
            
            if parent.showClusters {
                return createClusteredAnnotationView(mapView: mapView, annotation: cameraAnnotation)
            } else {
                return createStandardAnnotationView(mapView: mapView, annotation: cameraAnnotation)
            }
        }
        
        private func createClusteredAnnotationView(mapView: MKMapView, annotation: CameraAnnotation) -> MKAnnotationView? {
            let identifier = "ClusteredCamera"
            var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
            
            if view == nil {
                view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view?.canShowCallout = false
                (view as? MKMarkerAnnotationView)?.clusteringIdentifier = "camera-cluster"
            } else {
                view?.annotation = annotation
            }
            
            if let markerView = view as? MKMarkerAnnotationView {
                markerView.glyphImage = UIImage(systemName: "video.fill")
                markerView.markerTintColor = annotation.camera.isOnline ? .systemGreen : .systemGray
                markerView.displayPriority = annotation.camera.isOnline ? .required : .defaultLow
                
                // Smooth animation
                markerView.animatesWhenAdded = true
            }
            
            return view
        }
        
        private func createStandardAnnotationView(mapView: MKMapView, annotation: CameraAnnotation) -> MKAnnotationView? {
            let identifier = "StandardCamera"
            var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
            
            if view == nil {
                view = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view?.canShowCallout = false
            } else {
                view?.annotation = annotation
            }
            
            let camera = annotation.camera
            let size = CGSize(width: 50, height: 50)
            let image = createCameraMarker(camera: camera, size: size)
            
            view?.image = image
            view?.centerOffset = CGPoint(x: 0, y: -size.height / 2)
            
            // Add pulsing animation for online cameras
            if camera.isOnline && parent.selectedCamera?.id != camera.id {
                addPulseAnimation(to: view)
            }
            
            // Selection highlight
            if let selected = parent.selectedCamera, selected.id == camera.id {
                view?.transform = CGAffineTransform(scaleX: 1.3, y: 1.3)
                view?.layer.removeAllAnimations()
            } else {
                view?.transform = .identity
            }
            
            return view
        }
        
        // MARK: - Cluster View
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let cluster = annotation as? MKClusterAnnotation {
                let identifier = "CameraCluster"
                var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                
                if view == nil {
                    view = MKMarkerAnnotationView(annotation: cluster, reuseIdentifier: identifier)
                    view?.canShowCallout = false
                }
                
                view?.annotation = cluster
                
                let cameraAnnotations = cluster.memberAnnotations.compactMap { $0 as? CameraAnnotation }
                let onlineCount = cameraAnnotations.filter { $0.camera.isOnline }.count
                let totalCount = cameraAnnotations.count
                
                view?.glyphText = "\(totalCount)"
                view?.markerTintColor = onlineCount > 0 ? .systemGreen : .systemGray
                view?.displayPriority = .required
                
                return view
            }
            
            return nil
        }
        
        // MARK: - Selection Handling
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            // Handle cluster tap - zoom in
            if let cluster = view.annotation as? MKClusterAnnotation {
                let members = cluster.memberAnnotations
                var minLat = 90.0, maxLat = -90.0
                var minLng = 180.0, maxLng = -180.0
                
                for member in members {
                    let coord = member.coordinate
                    minLat = min(minLat, coord.latitude)
                    maxLat = max(maxLat, coord.latitude)
                    minLng = min(minLng, coord.longitude)
                    maxLng = max(maxLng, coord.longitude)
                }
                
                let center = CLLocationCoordinate2D(
                    latitude: (minLat + maxLat) / 2,
                    longitude: (minLng + maxLng) / 2
                )
                let span = MKCoordinateSpan(
                    latitudeDelta: (maxLat - minLat) * 2,
                    longitudeDelta: (maxLng - minLng) * 2
                )
                
                let region = MKCoordinateRegion(center: center, span: span)
                mapView.setRegion(region, animated: true)
                mapView.deselectAnnotation(cluster, animated: false)
                return
            }
            
            // Handle camera tap
            guard let cameraAnnotation = view.annotation as? CameraAnnotation else { return }
            
            // Smooth selection animation
            UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.5, initialSpringVelocity: 0.5) {
                view.transform = CGAffineTransform(scaleX: 1.3, y: 1.3)
            }
            
            // Haptic feedback
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    self.parent.selectedCamera = cameraAnnotation.camera
                }
            }
            
            // Center camera on screen
            let coordinate = cameraAnnotation.coordinate
            mapView.setCenter(coordinate, animated: true)
            
            mapView.deselectAnnotation(view.annotation, animated: false)
        }
        
        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            UIView.animate(withDuration: 0.3) {
                view.transform = .identity
            }
        }
        
        // MARK: - Overlay Rendering
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let heatmap = overlay as? HeatmapOverlay {
                return HeatmapOverlayRenderer(overlay: heatmap)
            }
            if let tileOverlay = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tileOverlay)
            }
            return MKOverlayRenderer(overlay: overlay)
        }
        
        // MARK: - User Interaction Tracking
        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            isUserInteracting = true
        }
        
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            isUserInteracting = false
            DispatchQueue.main.async {
                self.parent.region = mapView.region
            }
        }
        
        // MARK: - Heatmap Management
        func updateHeatmap(mapView: MKMapView, cameras: [Camera]) {
            removeHeatmap(mapView: mapView)
            
            let onlineCameras = cameras.filter { $0.isOnline }
            guard !onlineCameras.isEmpty else { return }
            
            var points: [(coordinate: CLLocationCoordinate2D, intensity: Double)] = []
            
            for camera in onlineCameras {
                guard let lat = Double(camera.latitude),
                      let lng = Double(camera.longitude),
                      lat != 0, lng != 0 else { continue }
                
                let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
                points.append((coordinate: coordinate, intensity: 1.0))
            }
            
            if !points.isEmpty {
                heatmapOverlay = HeatmapOverlay(points: points)
                mapView.addOverlay(heatmapOverlay!, level: .aboveLabels)
            }
        }
        
        func removeHeatmap(mapView: MKMapView) {
            if let overlay = heatmapOverlay {
                mapView.removeOverlay(overlay)
                heatmapOverlay = nil
            }
        }
        
        // MARK: - Animations
        private func addPulseAnimation(to view: MKAnnotationView?) {
            guard let view = view else { return }
            
            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.duration = 1.5
            pulse.fromValue = 1.0
            pulse.toValue = 1.15
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            
            view.layer.add(pulse, forKey: "pulse")
        }
        
        private func createCameraMarker(camera: Camera, size: CGSize) -> UIImage {
            let renderer = UIGraphicsImageRenderer(size: size)
            
            return renderer.image { ctx in
                // Shadow
                ctx.cgContext.setShadow(
                    offset: CGSize(width: 0, height: 3),
                    blur: 8,
                    color: UIColor.black.withAlphaComponent(0.3).cgColor
                )
                
                // Outer circle with gradient
                let outerCircle = CGRect(x: 2, y: 2, width: size.width - 4, height: size.height - 4)
                let gradient: CGGradient
                
                if camera.isOnline {
                    let colors = [
                        UIColor.systemGreen.cgColor,
                        UIColor.systemGreen.darker().cgColor
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
                
                let iconColor = camera.isOnline ? UIColor.systemGreen : UIColor.systemGray
                if let icon = UIImage(systemName: "video.fill")?.withTintColor(iconColor, renderingMode: .alwaysOriginal) {
                    icon.draw(in: iconRect)
                }
                
                // Live indicator
                if camera.isOnline {
                    let indicator = CGRect(x: 32, y: 2, width: 16, height: 16)
                    UIColor.white.setFill()
                    ctx.cgContext.fillEllipse(in: indicator)
                    
                    UIColor.systemGreen.setFill()
                    ctx.cgContext.fillEllipse(in: indicator.insetBy(dx: 2, dy: 2))
                }
            }
        }
    }
}

// MARK: - Camera Annotation
class CameraAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let camera: Camera
    
    var title: String? { camera.displayName }
    var subtitle: String? { "\(camera.area) • \(camera.isOnline ? "Online" : "Offline")" }
    
    init(coordinate: CLLocationCoordinate2D, camera: Camera) {
        self.coordinate = coordinate
        self.camera = camera
    }
}

// MARK: - Heatmap Overlay
class HeatmapOverlay: NSObject, MKOverlay {
    let points: [(coordinate: CLLocationCoordinate2D, intensity: Double)]
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect
    
    init(points: [(coordinate: CLLocationCoordinate2D, intensity: Double)]) {
        self.points = points
        
        var minLat = 90.0, maxLat = -90.0
        var minLng = 180.0, maxLng = -180.0
        
        for point in points {
            minLat = min(minLat, point.coordinate.latitude)
            maxLat = max(maxLat, point.coordinate.latitude)
            minLng = min(minLng, point.coordinate.longitude)
            maxLng = max(maxLng, point.coordinate.longitude)
        }
        
        self.coordinate = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLng + maxLng) / 2
        )
        
        let topLeft = MKMapPoint(CLLocationCoordinate2D(latitude: maxLat, longitude: minLng))
        let bottomRight = MKMapPoint(CLLocationCoordinate2D(latitude: minLat, longitude: maxLng))
        
        self.boundingMapRect = MKMapRect(
            x: topLeft.x,
            y: topLeft.y,
            width: bottomRight.x - topLeft.x,
            height: bottomRight.y - topLeft.y
        )
    }
}

// MARK: - Heatmap Renderer
class HeatmapOverlayRenderer: MKOverlayRenderer {
    private let heatmapOverlay: HeatmapOverlay
    
    init(overlay: HeatmapOverlay) {
        self.heatmapOverlay = overlay
        super.init(overlay: overlay)
    }
    
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let rect = self.rect(for: mapRect)
        
        guard !rect.isEmpty else { return }
        
        // Create gradient
        let colors = [
            UIColor.green.withAlphaComponent(0.0).cgColor,
            UIColor.green.withAlphaComponent(0.3).cgColor,
            UIColor.green.withAlphaComponent(0.6).cgColor
        ] as CFArray
        
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0.0, 0.5, 1.0]
        ) else { return }
        
        // Draw heat points
        for point in heatmapOverlay.points {
            let mapPoint = MKMapPoint(point.coordinate)
            let pointRect = self.rect(for: MKMapRect(
                origin: mapPoint,
                size: MKMapSize(width: 0, height: 0)
            ))
            
            let radius = 50.0 / zoomScale
            let center = CGPoint(x: pointRect.midX, y: pointRect.midY)
            
            context.drawRadialGradient(
                gradient,
                startCenter: center,
                startRadius: 0,
                endCenter: center,
                endRadius: radius,
                options: .drawsAfterEndLocation
            )
        }
    }
}
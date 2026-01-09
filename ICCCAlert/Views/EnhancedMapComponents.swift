import SwiftUI
import MapKit

// MARK: - Enhanced Camera Map with Custom Styling

struct EnhancedCameraMapView: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    let cameras: [Camera]
    @Binding var selectedCamera: Camera?
    let mapStyle: MapDisplayStyle
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        
        // Enable user interaction
        mapView.isZoomEnabled = true
        mapView.isScrollEnabled = true
        mapView.isRotateEnabled = true
        mapView.isPitchEnabled = true
        mapView.showsCompass = true
        mapView.showsScale = true
        
        // Apply initial map style
        applyMapStyle(mapView, style: mapStyle)
        
        return mapView
    }
    
    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Update region with animation
        mapView.setRegion(region, animated: true)
        
        // Apply map style
        applyMapStyle(mapView, style: mapStyle)
        
        // Remove old annotations
        mapView.removeAnnotations(mapView.annotations)
        
        // Add camera annotations with clustering
        for camera in cameras {
            guard let lat = Double(camera.latitude),
                  let lng = Double(camera.longitude),
                  lat != 0, lng != 0 else {
                continue
            }
            
            let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            let annotation = EnhancedCameraAnnotation(
                coordinate: coordinate,
                camera: camera
            )
            mapView.addAnnotation(annotation)
        }
    }
    
    private func applyMapStyle(_ mapView: MKMapView, style: MapDisplayStyle) {
        // Remove existing overlays
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
            // Use default Apple Maps
            break
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: EnhancedCameraMapView
        
        init(_ parent: EnhancedCameraMapView) {
            self.parent = parent
        }
        
        // ✅ Enhanced Camera Pin with Modern Design
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let cameraAnnotation = annotation as? EnhancedCameraAnnotation else { return nil }
            
            let identifier = "EnhancedCameraPin"
            var annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
            
            if annotationView == nil {
                annotationView = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                annotationView?.canShowCallout = false
            } else {
                annotationView?.annotation = annotation
            }
            
            // ✅ Create Modern Camera Marker
            let camera = cameraAnnotation.camera
            let size = CGSize(width: 50, height: 50)
            let renderer = UIGraphicsImageRenderer(size: size)
            
            let image = renderer.image { ctx in
                // Shadow
                let shadowPath = UIBezierPath(ovalIn: CGRect(x: 5, y: 5, width: size.width - 10, height: size.height - 10))
                ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 2), blur: 8, color: UIColor.black.withAlphaComponent(0.4).cgColor)
                
                // Outer ring (gradient)
                let outerCircle = CGRect(x: 2, y: 2, width: size.width - 4, height: size.height - 4)
                
                let gradient: CGGradient
                if camera.isOnline {
                    let colors = [
                        UIColor.systemGreen.cgColor,
                        UIColor.systemGreen.darker().cgColor
                    ]
                    gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
                } else {
                    let colors = [
                        UIColor.systemGray.cgColor,
                        UIColor.systemGray.darker().cgColor
                    ]
                    gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
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
                
                // Inner white circle
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
                if let cameraIcon = UIImage(systemName: "video.fill")?.withTintColor(iconColor, renderingMode: .alwaysOriginal) {
                    cameraIcon.draw(in: iconRect)
                }
                
                // Online indicator pulse (for online cameras)
                if camera.isOnline {
                    let pulseCircle = CGRect(x: 32, y: 2, width: 16, height: 16)
                    
                    // White background
                    UIColor.white.setFill()
                    ctx.cgContext.fillEllipse(in: pulseCircle)
                    
                    // Green pulse
                    UIColor.systemGreen.setFill()
                    let innerPulse = pulseCircle.insetBy(dx: 2, dy: 2)
                    ctx.cgContext.fillEllipse(in: innerPulse)
                }
            }
            
            annotationView?.image = image
            annotationView?.centerOffset = CGPoint(x: 0, y: -size.height / 2)
            
            // Add subtle animation for selection
            if let selected = parent.selectedCamera, selected.id == camera.id {
                annotationView?.transform = CGAffineTransform(scaleX: 1.2, y: 1.2)
            } else {
                annotationView?.transform = .identity
            }
            
            return annotationView
        }
        
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let cameraAnnotation = view.annotation as? EnhancedCameraAnnotation else { return }
            
            // Animate selection
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0.5, options: []) {
                view.transform = CGAffineTransform(scaleX: 1.2, y: 1.2)
            }
            
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    self.parent.selectedCamera = cameraAnnotation.camera
                }
            }
            
            // Deselect to allow re-selection
            mapView.deselectAnnotation(view.annotation, animated: false)
        }
        
        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            // Animate deselection
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

// MARK: - Google Satellite Tile Overlay

class GoogleSatelliteTileOverlay: MKTileOverlay {
    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        let urlString = "https://mt1.google.com/vt/lyrs=s&x=\(path.x)&y=\(path.y)&z=\(path.z)"
        return URL(string: urlString)!
    }
}

// MARK: - Modern Camera Info Card

struct ModernCameraInfoCard: View {
    let camera: Camera
    let onClose: () -> Void
    let onView: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with gradient
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
                // Location Info
                VStack(alignment: .leading, spacing: 12) {
                    InfoRow(icon: "map.fill", label: "Area", value: camera.area, color: .blue)
                    InfoRow(icon: "location.fill", label: "Location", value: camera.location.isEmpty ? "Unknown" : camera.location, color: .purple)
                    
                    if camera.isOnline && camera.webrtcStreamURL != nil {
                        InfoRow(icon: "antenna.radiowaves.left.and.right", label: "Stream", value: "WebRTC Available", color: .green)
                    }
                }
                
                // Action Button
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

struct InfoRow: View {
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

// MARK: - Map Display Style

enum MapDisplayStyle: String, CaseIterable {
    case hybrid = "Hybrid"
    case satellite = "Satellite"
    case standard = "Standard"
}

// MARK: - Blur View for iOS Compatibility

struct BlurView: UIViewRepresentable {
    let style: UIBlurEffect.Style
    
    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }
    
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}

// MARK: - UIColor Extension for Gradient

extension UIColor {
    func darker(by percentage: CGFloat = 0.2) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        self.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return UIColor(hue: h, saturation: s, brightness: max(b * (1 - percentage), 0), alpha: a)
    }
}
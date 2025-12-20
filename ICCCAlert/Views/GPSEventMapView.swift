import SwiftUI
import MapKit

// MARK: - GPS Event Map View (Google Hybrid Tiles - FREE, No API Key)

struct GPSEventMapView: View {
    let event: Event
    @Environment(\.presentationMode) var presentationMode
    
    @State private var region: MKCoordinateRegion
    @State private var annotations: [IdentifiableAnnotation] = []
    
    init(event: Event) {
        self.event = event
        
        // Initialize region with alert location or Jharkhand default
        if let alertLoc = event.gpsAlertLocation {
            _region = State(initialValue: MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: alertLoc.lat, longitude: alertLoc.lng),
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            ))
        } else {
            // Jharkhand state center (same as Android)
            _region = State(initialValue: MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 23.6102, longitude: 85.2799),
                span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
            ))
        }
    }
    
    var body: some View {
        ZStack {
            // Map using Google Hybrid tiles (FREE - same as Android)
            GoogleHybridMapView(
                region: $region,
                annotations: annotations,
                event: event
            )
            .edgesIgnoringSafeArea(.all)
            
            // Header Overlay
            VStack(spacing: 0) {
                headerView
                Spacer()
            }
            
            // Legend only
            VStack {
                Spacer()
                HStack {
                    legendView
                    Spacer()
                }
                .padding()
            }
        }
        .onAppear {
            setupMapData()
        }
        .navigationBarHidden(true)
    }
    
    private var headerView: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                // Back Button
                Button(action: { presentationMode.wrappedValue.dismiss() }) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.primary)
                }
                
                // Event Type
                Text(event.typeDisplay ?? "GPS Alert")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                // Vehicle Info Row
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Vehicle Number")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(event.vehicleNumber ?? "Unknown")
                            .font(.subheadline)
                            .font(.system(size: 15, weight: .medium))
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Transporter")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(event.vehicleTransporter ?? "Unknown")
                            .font(.subheadline)
                            .font(.system(size: 15, weight: .medium))
                    }
                }
                
                // Coordinates and Time Row
                HStack(spacing: 20) {
                    if let alertLoc = event.gpsAlertLocation {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Coordinates")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            HStack(spacing: 4) {
                                Image(systemName: "location.fill")
                                    .font(.caption)
                                    .foregroundColor(.red)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(String(format: "%.6f", alertLoc.lat))
                                        .font(.system(size: 13, weight: .medium))
                                    Text(String(format: "%.6f", alertLoc.lng))
                                        .font(.system(size: 13, weight: .medium))
                                }
                            }
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Time")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(formatTime(event.date))
                                .font(.system(size: 13, weight: .medium))
                            Text(formatDate(event.date))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                // Area Info
                VStack(alignment: .leading, spacing: 4) {
                    Text("Area")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(event.areaDisplay ?? event.area ?? "Unknown")
                        .font(.subheadline)
                        .font(.system(size: 15, weight: .medium))
                }
                
                // Alert Subtype (for tamper)
                if let subType = event.alertSubType {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Alert Type")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(subType)
                            .font(.subheadline)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.orange)
                    }
                }
            }
            .padding()
            .background(Color(.systemBackground))
            .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
        }
    }
    
    private var legendView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 12, height: 12)
                Text(legendText)
                    .font(.caption)
            }
            
            if event.geofenceInfo != nil {
                HStack(spacing: 8) {
                    Rectangle()
                        .fill(geofenceColor)
                        .frame(width: 12, height: 3)
                    Text("Geofence")
                        .font(.caption)
                }
            }
        }
        .padding(12)
        .background(Color(.systemBackground).opacity(0.95))
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.1), radius: 5)
    }
    
    private var legendText: String {
        switch event.type {
        case "off-route": return "Off-Route Point"
        case "tamper": return "Tamper Location"
        case "overspeed": return "Overspeed Point"
        default: return "Alert Location"
        }
    }
    
    private var geofenceColor: Color {
        // Get color from attributes (priority: color > polylineColor)
        if let colorStr = event.geofenceInfo?.attributes?.color ?? event.geofenceInfo?.attributes?.polylineColor {
            return Color(hex: colorStr)
        }
        // Default based on type
        if event.geofenceInfo?.type == "P" {
            return Color(hex: "#FFC107") // Yellow for paths
        }
        return Color(hex: "#3388ff") // Blue default
    }
    
    private func setupMapData() {
        var tempAnnotations: [IdentifiableAnnotation] = []
        var coordinates: [CLLocationCoordinate2D] = []
        
        // Add alert location marker (PRIMARY - same as Android)
        if let alertLoc = event.gpsAlertLocation {
            let coord = CLLocationCoordinate2D(latitude: alertLoc.lat, longitude: alertLoc.lng)
            let title = legendText
            
            tempAnnotations.append(IdentifiableAnnotation(
                coordinate: coord,
                title: title,
                subtitle: "Vehicle: \(event.vehicleNumber ?? "Unknown")",
                color: .red
            ))
            coordinates.append(coord)
            
            // For tamper events without geofence, add padding points
            if event.type == "tamper" && event.geofenceInfo == nil {
                let padding = 0.002 // ~200 meters
                coordinates.append(CLLocationCoordinate2D(latitude: alertLoc.lat + padding, longitude: alertLoc.lng))
                coordinates.append(CLLocationCoordinate2D(latitude: alertLoc.lat - padding, longitude: alertLoc.lng))
                coordinates.append(CLLocationCoordinate2D(latitude: alertLoc.lat, longitude: alertLoc.lng + padding))
                coordinates.append(CLLocationCoordinate2D(latitude: alertLoc.lat, longitude: alertLoc.lng - padding))
            }
        }
        
        // Show current location only if different (>11 meters)
        if let currentLoc = event.gpsCurrentLocation,
           let alertLoc = event.gpsAlertLocation {
            let latDiff = abs(currentLoc.lat - alertLoc.lat)
            let lngDiff = abs(currentLoc.lng - alertLoc.lng)
            
            if latDiff > 0.0001 || lngDiff > 0.0001 { // ~11 meters
                let coord = CLLocationCoordinate2D(latitude: currentLoc.lat, longitude: currentLoc.lng)
                tempAnnotations.append(IdentifiableAnnotation(
                    coordinate: coord,
                    title: "Current Location",
                    subtitle: "Latest position",
                    color: .orange
                ))
                coordinates.append(coord)
            }
        }
        
        // Process geofence if available (for context)
        if let geofence = event.geofenceInfo,
           let geojson = geofence.geojson,
           let coords = geojson.coordinatesArray {
            
            switch geojson.type {
            case "Point":
                if let first = coords.first, first.count >= 2 {
                    let coord = CLLocationCoordinate2D(latitude: first[1], longitude: first[0])
                    coordinates.append(coord)
                    // Add padding for point geofences
                    let padding = 0.002
                    coordinates.append(CLLocationCoordinate2D(latitude: first[1] + padding, longitude: first[0]))
                    coordinates.append(CLLocationCoordinate2D(latitude: first[1] - padding, longitude: first[0]))
                }
                
            case "LineString", "Polygon":
                let lineCoords = coords.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }
                coordinates.append(contentsOf: lineCoords)
                
            default:
                break
            }
        }
        
        annotations = tempAnnotations
        
        // Adjust region to fit all coordinates (same as Android zoomToBoundingBox)
        if !coordinates.isEmpty {
            let minLat = coordinates.map { $0.latitude }.min() ?? 0
            let maxLat = coordinates.map { $0.latitude }.max() ?? 0
            let minLng = coordinates.map { $0.longitude }.min() ?? 0
            let maxLng = coordinates.map { $0.longitude }.max() ?? 0
            
            let center = CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2,
                longitude: (minLng + maxLng) / 2
            )
            
            let span = MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * 1.5, 0.01),
                longitudeDelta: max((maxLng - minLng) * 1.5, 0.01)
            )
            
            region = MKCoordinateRegion(center: center, span: span)
        }
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM dd, yyyy"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }
}

// MARK: - Identifiable Annotation

struct IdentifiableAnnotation: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let title: String
    let subtitle: String
    let color: Color
}

// MARK: - Google Hybrid Map View (FREE Tiles - No API Key Required)

struct GoogleHybridMapView: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    let annotations: [IdentifiableAnnotation]
    let event: Event
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        
        // Use Google Hybrid tile overlay (FREE - same as Android)
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
        
        // Remove old overlays (except tile overlay)
        _ = mapView.overlays.first { $0 is GoogleHybridTileOverlay }
        mapView.removeOverlays(mapView.overlays.filter { !($0 is GoogleHybridTileOverlay) })
        
        // Add new annotations
        for annotation in annotations {
            let mkAnnotation = CustomMapAnnotation(
                coordinate: annotation.coordinate,
                title: annotation.title,
                subtitle: annotation.subtitle,
                color: annotation.color
            )
            mapView.addAnnotation(mkAnnotation)
        }
        
        // Add geofence overlay if available
        if let geofence = event.geofenceInfo,
           let geojson = geofence.geojson,
           let coords = geojson.coordinatesArray {
            
            // Get color from attributes (priority: color > polylineColor)
            let colorStr: String
            if let color = geofence.attributes?.color {
                colorStr = color
            } else if let polylineColor = geofence.attributes?.polylineColor {
                colorStr = polylineColor
            } else if geofence.type == "P" {
                colorStr = "#FFC107" // Yellow for paths
            } else {
                colorStr = "#3388ff" // Blue default
            }
            
            let color = UIColor(Color(hex: colorStr))
            
            // Determine stroke width based on geofence type (same as Android)
            let strokeWidth: CGFloat = (geofence.type == "P") ? 8.0 : 5.0
            
            switch geojson.type {
            case "Point":
                // Draw circle for point geofences
                if let first = coords.first, first.count >= 2 {
                    let center = CLLocationCoordinate2D(latitude: first[1], longitude: first[0])
                    let circle = MKCircle(center: center, radius: 100) // 100m radius
                    mapView.addOverlay(circle)
                    context.coordinator.overlayColor = color
                    context.coordinator.overlayStrokeWidth = 3.0
                }
                
            case "LineString":
                let coordinates = coords.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }
                let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
                mapView.addOverlay(polyline)
                context.coordinator.overlayColor = color
                context.coordinator.overlayStrokeWidth = strokeWidth
                
            case "Polygon":
                let coordinates = coords.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }
                let polygon = MKPolygon(coordinates: coordinates, count: coordinates.count)
                mapView.addOverlay(polygon)
                context.coordinator.overlayColor = color
                context.coordinator.overlayStrokeWidth = 4.0
                
            default:
                break
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: GoogleHybridMapView
        var overlayColor: UIColor = .blue
        var overlayStrokeWidth: CGFloat = 3.0
        
        init(_ parent: GoogleHybridMapView) {
            self.parent = parent
        }
        
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let customAnnotation = annotation as? CustomMapAnnotation else { return nil }
            
            let identifier = "CustomPin"
            var annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
            
            if annotationView == nil {
                annotationView = MKPinAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                annotationView?.canShowCallout = true
            } else {
                annotationView?.annotation = annotation
            }
            
            if let pinView = annotationView as? MKPinAnnotationView {
                pinView.pinTintColor = UIColor(customAnnotation.color)
            }
            
            return annotationView
        }
        
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            // Google Hybrid tile overlay
            if let tileOverlay = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tileOverlay)
            }
            
            // Circle overlay (for Point geofences)
            if let circle = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.fillColor = overlayColor.withAlphaComponent(0.2)
                renderer.strokeColor = overlayColor
                renderer.lineWidth = overlayStrokeWidth
                return renderer
            }
            
            // Polyline overlay (for LineString geofences)
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = overlayColor
                renderer.lineWidth = overlayStrokeWidth
                return renderer
            }
            
            // Polygon overlay (for Polygon geofences)
            if let polygon = overlay as? MKPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                renderer.strokeColor = overlayColor
                renderer.fillColor = overlayColor.withAlphaComponent(0.3)
                renderer.lineWidth = overlayStrokeWidth
                return renderer
            }
            
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

// MARK: - Google Hybrid Tile Overlay (FREE - No API Key)

class GoogleHybridTileOverlay: MKTileOverlay {
    private let tileServers = [
        "https://mt0.google.com/vt/lyrs=y&hl=en",
        "https://mt1.google.com/vt/lyrs=y&hl=en",
        "https://mt2.google.com/vt/lyrs=y&hl=en",
        "https://mt3.google.com/vt/lyrs=y&hl=en"
    ]
    
    override init(urlTemplate URLTemplate: String?) {
        super.init(urlTemplate: URLTemplate)
        self.minimumZ = 0
        self.maximumZ = 22
        self.tileSize = CGSize(width: 256, height: 256)
    }
    
    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        let zoom = path.z
        let x = path.x
        let y = path.y
        
        // Load balance across servers (same as Android)
        let serverIndex = (x + y) % tileServers.count
        let baseUrl = tileServers[serverIndex]
        
        // Same URL format as Android MapActivity
        let urlString = "\(baseUrl)&x=\(x)&y=\(y)&z=\(zoom)&s=Ga"
        
        return URL(string: urlString)!
    }
}

// MARK: - Custom Map Annotation

class CustomMapAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?
    let color: Color
    
    init(coordinate: CLLocationCoordinate2D, title: String, subtitle: String, color: Color) {
        self.coordinate = coordinate
        self.title = title
        self.subtitle = subtitle
        self.color = color
    }
}
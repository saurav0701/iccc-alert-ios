import SwiftUI
import MapKit

// MARK: - GPS Event Map View

struct GPSEventMapView: View {
    let event: Event
    @Environment(\.presentationMode) var presentationMode
    
    @State private var region: MKCoordinateRegion
    @State private var annotations: [IdentifiableAnnotation] = []
    
    init(event: Event) {
        self.event = event
        
        // Initialize region with alert location or default
        if let alertLoc = event.gpsAlertLocation {
            _region = State(initialValue: MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: alertLoc.lat, longitude: alertLoc.lng),
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            ))
        } else {
            _region = State(initialValue: MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 23.7645, longitude: 86.1423),
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            ))
        }
    }
    
    var body: some View {
        ZStack {
            // Map using iOS 14 compatible API
            MapViewRepresentable(
                region: $region,
                annotations: annotations,
                event: event
            )
            .edgesIgnoringSafeArea(.all)
            
            // Header Overlay
            VStack(spacing: 0) {
                headerView
                Spacer()
                bottomInfoView
            }
            
            // Legend and Coordinates
            VStack {
                Spacer()
                HStack {
                    legendView
                    Spacer()
                    coordinatesView
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
                
                // Vehicle Info
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Vehicle Number")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(event.vehicleNumber ?? "Unknown")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Transporter")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(event.vehicleTransporter ?? "Unknown")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                }
                
                // Alert Subtype (for tamper)
                if let subType = event.alertSubType {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Alert Type")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(subType)
                            .font(.subheadline)
                            .fontWeight(.medium)
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
                Text("Alert Location")
                    .font(.caption)
            }
            
            if event.geofenceInfo != nil {
                HStack(spacing: 8) {
                    Rectangle()
                        .fill(Color.blue)
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
    
    private var coordinatesView: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let alertLoc = event.gpsAlertLocation {
                HStack(spacing: 4) {
                    Image(systemName: "location.fill")
                        .font(.caption)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.6f", alertLoc.lat))
                            .font(.caption)
                            .fontWeight(.medium)
                        Text(String(format: "%.6f", alertLoc.lng))
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.systemBackground).opacity(0.95))
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.1), radius: 5)
    }
    
    private var bottomInfoView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Area")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(event.areaDisplay ?? event.area ?? "Unknown")
                    .font(.subheadline)
                    .font(.system(size: 15, weight: .medium))
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 4) {
                Text("Time")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 4) {
                    Text(formatTime(event.date))
                    Text("•")
                    Text(formatDate(event.date))
                }
                .font(.subheadline)
                .font(.system(size: 15, weight: .medium))
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: -2)
    }
    
    private func setupMapData() {
        var tempAnnotations: [IdentifiableAnnotation] = []
        var coordinates: [CLLocationCoordinate2D] = []
        
        // Add alert location marker
        if let alertLoc = event.gpsAlertLocation {
            let coord = CLLocationCoordinate2D(latitude: alertLoc.lat, longitude: alertLoc.lng)
            tempAnnotations.append(IdentifiableAnnotation(
                coordinate: coord,
                title: "Alert Location",
                subtitle: event.typeDisplay ?? "GPS Alert",
                color: .red
            ))
            coordinates.append(coord)
        }
        
        // Process geofence if available
        if let geofence = event.geofenceInfo,
           let geojson = geofence.geojson,
           let coords = geojson.coordinatesArray {
            
            switch geojson.type {
            case "Point":
                if let first = coords.first, first.count >= 2 {
                    let coord = CLLocationCoordinate2D(latitude: first[1], longitude: first[0])
                    tempAnnotations.append(IdentifiableAnnotation(
                        coordinate: coord,
                        title: geofence.name ?? "Geofence",
                        subtitle: "Geofence Point",
                        color: .blue
                    ))
                    coordinates.append(coord)
                }
                
            case "LineString", "Polygon":
                let lineCoords = coords.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }
                coordinates.append(contentsOf: lineCoords)
                
            default:
                break
            }
        }
        
        annotations = tempAnnotations
        
        // Adjust region to fit all coordinates
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

// MARK: - Identifiable Annotation (iOS 14 Compatible)

struct IdentifiableAnnotation: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let title: String
    let subtitle: String
    let color: Color
}

// MARK: - MapView Representable (UIKit Wrapper)

struct MapViewRepresentable: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    let annotations: [IdentifiableAnnotation]
    let event: Event
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        return mapView
    }
    
    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Update region
        mapView.setRegion(region, animated: true)
        
        // Remove old annotations
        mapView.removeAnnotations(mapView.annotations)
        
        // Remove old overlays
        mapView.removeOverlays(mapView.overlays)
        
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
            
            let color = UIColor(Color(hex: geofence.attributes?.polylineColor ?? geofence.attributes?.color ?? "#3388ff"))
            
            switch geojson.type {
            case "LineString":
                let coordinates = coords.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }
                let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
                mapView.addOverlay(polyline)
                context.coordinator.overlayColor = color
                
            case "Polygon":
                let coordinates = coords.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }
                let polygon = MKPolygon(coordinates: coordinates, count: coordinates.count)
                mapView.addOverlay(polygon)
                context.coordinator.overlayColor = color
                
            default:
                break
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: MapViewRepresentable
        var overlayColor: UIColor = .blue
        
        init(_ parent: MapViewRepresentable) {
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
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = overlayColor
                renderer.lineWidth = 3
                return renderer
            } else if let polygon = overlay as? MKPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                renderer.strokeColor = overlayColor
                renderer.fillColor = overlayColor.withAlphaComponent(0.2)
                renderer.lineWidth = 2
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
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
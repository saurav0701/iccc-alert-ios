import SwiftUI
import MapKit

// MARK: - GPS Event Map View

struct GPSEventMapView: View {
    let event: Event
    @Environment(\.presentationMode) var presentationMode
    
    @State private var region: MKCoordinateRegion
    @State private var annotations: [MapAnnotation] = []
    @State private var overlays: [MapOverlay] = []
    
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
            // Map
            Map(coordinateRegion: $region,
                interactionModes: .all,
                showsUserLocation: false,
                annotationItems: annotations) { annotation in
                MapAnnotation(coordinate: annotation.coordinate) {
                    VStack(spacing: 0) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(annotation.color)
                            .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 2)
                        
                        Text(annotation.label)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(annotation.color)
                            .cornerRadius(8)
                            .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
                    }
                }
            }
            .edgesIgnoringSafeArea(.all)
            
            // Header Overlay
            VStack(spacing: 0) {
                headerView
                Spacer()
                bottomInfoView
            }
            
            // Legend
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
            // Header Card
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
                    .fontWeight(.medium)
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
                .fontWeight(.medium)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: -2)
    }
    
    private func setupMapData() {
        var tempAnnotations: [MapAnnotation] = []
        var tempOverlays: [MapOverlay] = []
        var coordinates: [CLLocationCoordinate2D] = []
        
        // Add alert location marker
        if let alertLoc = event.gpsAlertLocation {
            let coord = CLLocationCoordinate2D(latitude: alertLoc.lat, longitude: alertLoc.lng)
            tempAnnotations.append(MapAnnotation(
                coordinate: coord,
                label: "Alert",
                color: .red
            ))
            coordinates.append(coord)
        }
        
        // Process geofence if available
        if let geofence = event.geofenceInfo,
           let geojson = geofence.geojson,
           let coords = geojson.coordinatesArray {
            
            let color = Color(hex: geofence.attributes?.polylineColor ?? geofence.attributes?.color ?? "#3388ff")
            
            switch geojson.type {
            case "Point":
                if let first = coords.first, first.count >= 2 {
                    let coord = CLLocationCoordinate2D(latitude: first[1], longitude: first[0])
                    tempAnnotations.append(MapAnnotation(
                        coordinate: coord,
                        label: geofence.name ?? "Geofence",
                        color: color
                    ))
                    coordinates.append(coord)
                }
                
            case "LineString":
                let lineCoords = coords.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }
                tempOverlays.append(MapOverlay(
                    type: .polyline,
                    coordinates: lineCoords,
                    color: color,
                    label: geofence.name
                ))
                coordinates.append(contentsOf: lineCoords)
                
            case "Polygon":
                let polygonCoords = coords.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }
                tempOverlays.append(MapOverlay(
                    type: .polygon,
                    coordinates: polygonCoords,
                    color: color,
                    label: geofence.name
                ))
                coordinates.append(contentsOf: polygonCoords)
                
            default:
                break
            }
        }
        
        annotations = tempAnnotations
        overlays = tempOverlays
        
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

// MARK: - Map Annotation Model

struct MapAnnotation: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let label: String
    let color: Color
}

// MARK: - Map Overlay Model

struct MapOverlay: Identifiable {
    let id = UUID()
    let type: OverlayType
    let coordinates: [CLLocationCoordinate2D]
    let color: Color
    let label: String?
    
    enum OverlayType {
        case polyline
        case polygon
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
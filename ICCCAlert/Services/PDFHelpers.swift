import Foundation
import UIKit
import MapKit
import SwiftUI

// MARK: - PDF Layout Helper

class PDFLayoutHelper {
    
    // MARK: - Draw Header
    
    static func drawHeader(
        channel: Channel,
        totalEvents: Int,
        pageWidth: CGFloat,
        margin: CGFloat,
        context: UIGraphicsPDFRendererContext
    ) {
        let titleFont = UIFont.boldSystemFont(ofSize: 20)
        let subtitleFont = UIFont.systemFont(ofSize: 14)
        let captionFont = UIFont.systemFont(ofSize: 11)
        
        var yPosition: CGFloat = margin
        
        // Company logo/title
        let companyText = "ICCC Event Manager"
        let companyAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 16),
            .foregroundColor: UIColor.systemBlue
        ]
        companyText.draw(at: CGPoint(x: margin, y: yPosition), withAttributes: companyAttributes)
        
        // Date on right
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM dd, yyyy HH:mm"
        let dateText = "Generated: \(dateFormatter.string(from: Date()))"
        let dateAttributes: [NSAttributedString.Key: Any] = [
            .font: captionFont,
            .foregroundColor: UIColor.darkGray
        ]
        let dateSize = dateText.size(withAttributes: dateAttributes)
        dateText.draw(at: CGPoint(x: pageWidth - margin - dateSize.width, y: yPosition), withAttributes: dateAttributes)
        
        yPosition += 25
        
        // Main title
        let titleText = "Events Report"
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: UIColor.black
        ]
        let titleSize = titleText.size(withAttributes: titleAttributes)
        titleText.draw(at: CGPoint(x: (pageWidth - titleSize.width) / 2, y: yPosition), withAttributes: titleAttributes)
        
        yPosition += 30
        
        // Channel info
        let channelText = "\(channel.eventTypeDisplay) - \(channel.areaDisplay)"
        let channelAttributes: [NSAttributedString.Key: Any] = [
            .font: subtitleFont,
            .foregroundColor: UIColor.darkGray
        ]
        let channelSize = channelText.size(withAttributes: channelAttributes)
        channelText.draw(at: CGPoint(x: (pageWidth - channelSize.width) / 2, y: yPosition), withAttributes: channelAttributes)
        
        yPosition += 25
        
        // Total events count
        let countText = "Total Events: \(totalEvents)"
        let countAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 12),
            .foregroundColor: UIColor.black
        ]
        let countSize = countText.size(withAttributes: countAttributes)
        countText.draw(at: CGPoint(x: (pageWidth - countSize.width) / 2, y: yPosition), withAttributes: countAttributes)
        
        yPosition += 20
        
        // Separator line
        context.cgContext.setStrokeColor(UIColor.systemBlue.cgColor)
        context.cgContext.setLineWidth(2)
        context.cgContext.move(to: CGPoint(x: margin, y: yPosition))
        context.cgContext.addLine(to: CGPoint(x: pageWidth - margin, y: yPosition))
        context.cgContext.strokePath()
    }
    
    // MARK: - Draw Footer
    
    static func drawFooter(
        pageNumber: Int,
        totalPages: Int,
        pageWidth: CGFloat,
        pageHeight: CGFloat,
        margin: CGFloat,
        context: UIGraphicsPDFRendererContext
    ) {
        let footerY = pageHeight - 40
        let captionFont = UIFont.systemFont(ofSize: 10)
        
        // Separator line
        context.cgContext.setStrokeColor(UIColor.lightGray.cgColor)
        context.cgContext.setLineWidth(1)
        context.cgContext.move(to: CGPoint(x: margin, y: footerY))
        context.cgContext.addLine(to: CGPoint(x: pageWidth - margin, y: footerY))
        context.cgContext.strokePath()
        
        // Page number (left)
        let pageText = "Page \(pageNumber) of \(totalPages)"
        let pageAttributes: [NSAttributedString.Key: Any] = [
            .font: captionFont,
            .foregroundColor: UIColor.gray
        ]
        pageText.draw(at: CGPoint(x: margin, y: footerY + 10), withAttributes: pageAttributes)
        
        // Company text (center)
        let companyText = "ICCC Event Manager - Events Report"
        let companyAttributes: [NSAttributedString.Key: Any] = [
            .font: captionFont,
            .foregroundColor: UIColor.gray
        ]
        let companySize = companyText.size(withAttributes: companyAttributes)
        companyText.draw(at: CGPoint(x: (pageWidth - companySize.width) / 2, y: footerY + 10), withAttributes: companyAttributes)
    }
    
    // MARK: - Draw Vertical Line
    
    static func drawVerticalLine(x: CGFloat, y: CGFloat, height: CGFloat, context: UIGraphicsPDFRendererContext) {
        context.cgContext.setStrokeColor(UIColor.lightGray.cgColor)
        context.cgContext.setLineWidth(0.5)
        context.cgContext.move(to: CGPoint(x: x, y: y))
        context.cgContext.addLine(to: CGPoint(x: x, y: y + height))
        context.cgContext.strokePath()
    }
}

// MARK: - PDF Map Renderer (Matches Live View EXACTLY)

class PDFMapRenderer {
    
    static func generateMapSnapshot(for event: Event) -> UIImage? {
        guard let alertLoc = event.gpsAlertLocation else {
            print("⚠️ No GPS location for event")
            return nil
        }
        
        // Use smaller size for PDF table cell (landscape orientation)
        let mapSize = CGSize(width: 600, height: 450)
        let options = MKMapSnapshotter.Options()
        
        // Set region
        let center = CLLocationCoordinate2D(latitude: alertLoc.lat, longitude: alertLoc.lng)
        
        // Calculate span to include geofence if available
        var span = MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        var coordinates: [CLLocationCoordinate2D] = [center]
        
        if let geofence = event.geofenceInfo,
           let geojson = geofence.geojson,
           let coords = geojson.coordinatesArray {
            
            switch geojson.type {
            case "Point":
                if let first = coords.first, first.count >= 2 {
                    let coord = CLLocationCoordinate2D(latitude: first[1], longitude: first[0])
                    coordinates.append(coord)
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
            
            // Calculate bounding box
            let lats = coordinates.map { $0.latitude }
            let lngs = coordinates.map { $0.longitude }
            
            if let minLat = lats.min(), let maxLat = lats.max(),
               let minLng = lngs.min(), let maxLng = lngs.max() {
                
                let latDelta = max((maxLat - minLat) * 1.5, 0.01)
                let lngDelta = max((maxLng - minLng) * 1.5, 0.01)
                span = MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lngDelta)
            }
        } else if event.type == "tamper" {
            let padding = 0.002
            coordinates.append(CLLocationCoordinate2D(latitude: alertLoc.lat + padding, longitude: alertLoc.lng))
            coordinates.append(CLLocationCoordinate2D(latitude: alertLoc.lat - padding, longitude: alertLoc.lng))
        }
        
        options.region = MKCoordinateRegion(center: center, span: span)
        options.size = mapSize
        options.scale = UIScreen.main.scale
        options.mapType = .standard
        
        let snapshotter = MKMapSnapshotter(options: options)
        let semaphore = DispatchSemaphore(value: 0)
        var resultImage: UIImage?
        
        snapshotter.start { snapshot, error in
            defer { semaphore.signal() }
            
            if let error = error {
                print("❌ Map snapshot error: \(error.localizedDescription)")
                return
            }
            
            guard let snapshot = snapshot else {
                print("❌ No snapshot generated")
                return
            }
            
            // Draw on the snapshot (MATCHING LIVE VIEW EXACTLY)
            UIGraphicsBeginImageContextWithOptions(mapSize, true, 0)
            
            // First draw the base map
            snapshot.image.draw(at: .zero)
            
            // Now overlay Google Hybrid tiles (same as live view)
            if let googleHybridImage = downloadGoogleHybridTiles(for: snapshot, event: event) {
                googleHybridImage.draw(at: .zero, blendMode: .normal, alpha: 1.0)
            }
            
            let context = UIGraphicsGetCurrentContext()
            
            // Draw geofence FIRST (so pin is on top - same as live view)
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
                let strokeWidth: CGFloat = (geofence.type == "P") ? 8.0 : 5.0
                
                context?.setStrokeColor(color.cgColor)
                context?.setLineWidth(strokeWidth)
                
                switch geojson.type {
                case "Point":
                    if let first = coords.first, first.count >= 2 {
                        let coord = CLLocationCoordinate2D(latitude: first[1], longitude: first[0])
                        let point = snapshot.point(for: coord)
                        
                        // Draw circle (same as live view)
                        context?.setFillColor(color.withAlphaComponent(0.2).cgColor)
                        context?.fillEllipse(in: CGRect(x: point.x - 80, y: point.y - 80, width: 160, height: 160))
                        context?.strokeEllipse(in: CGRect(x: point.x - 80, y: point.y - 80, width: 160, height: 160))
                    }
                    
                case "LineString":
                    let points = coords.map { snapshot.point(for: CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0])) }
                    if !points.isEmpty {
                        context?.move(to: points[0])
                        for point in points.dropFirst() {
                            context?.addLine(to: point)
                        }
                        context?.strokePath()
                    }
                    
                case "Polygon":
                    let points = coords.map { snapshot.point(for: CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0])) }
                    if !points.isEmpty {
                        context?.setFillColor(color.withAlphaComponent(0.3).cgColor)
                        context?.move(to: points[0])
                        for point in points.dropFirst() {
                            context?.addLine(to: point)
                        }
                        context?.closePath()
                        context?.drawPath(using: .fillStroke)
                    }
                    
                default:
                    break
                }
            }
            
            // NOW draw RED PIN at alert location (on top - same as live view)
            let pinPoint = snapshot.point(for: center)
            
            // Draw red pin with white center (EXACT same as live view)
            context?.setFillColor(UIColor.red.cgColor)
            context?.fillEllipse(in: CGRect(x: pinPoint.x - 15, y: pinPoint.y - 15, width: 30, height: 30))
            context?.setFillColor(UIColor.white.cgColor)
            context?.fillEllipse(in: CGRect(x: pinPoint.x - 8, y: pinPoint.y - 8, width: 16, height: 16))
            
            // Draw coordinates text below pin (EXACT same as live view)
            let coordText = String(format: "%.6f, %.6f", alertLoc.lat, alertLoc.lng)
            let textAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 12),
                .foregroundColor: UIColor.white,
                .strokeColor: UIColor.black,
                .strokeWidth: -3.0
            ]
            let textSize = coordText.size(withAttributes: textAttributes)
            let textRect = CGRect(
                x: pinPoint.x - textSize.width / 2,
                y: pinPoint.y + 20,
                width: textSize.width,
                height: textSize.height
            )
            
            // Draw background for text (EXACT same as live view)
            context?.setFillColor(UIColor.black.withAlphaComponent(0.6).cgColor)
            let bgRect = textRect.insetBy(dx: -8, dy: -4)
            context?.fill(bgRect)
            
            coordText.draw(in: textRect, withAttributes: textAttributes)
            
            resultImage = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()
        }
        
        _ = semaphore.wait(timeout: .now() + 15)
        
        if let image = resultImage {
            print("✅ Map snapshot generated matching live view")
        } else {
            print("⚠️ Failed to generate map snapshot")
        }
        
        return resultImage
    }
    
    // MARK: - Download Google Hybrid Tiles (Same as Live View)
    
    private static func downloadGoogleHybridTiles(for snapshot: MKMapSnapshotter.Snapshot, event: Event) -> UIImage? {
        // Calculate tile coordinates for the visible region
        let region = snapshot.mapSnapshotter.options.region
        let center = region.center
        let span = region.span
        
        // Get tile coordinates at zoom level 15 (good balance for our use case)
        let zoom = 15
        let tileCoords = getTileCoordinates(lat: center.latitude, lng: center.longitude, zoom: zoom)
        
        // Download the tile
        let tileServer = "https://mt0.google.com/vt/lyrs=y&hl=en"
        let urlString = "\(tileServer)&x=\(tileCoords.x)&y=\(tileCoords.y)&z=\(zoom)&s=Ga"
        
        guard let url = URL(string: urlString),
              let data = try? Data(contentsOf: url),
              let tileImage = UIImage(data: data) else {
            print("⚠️ Failed to download Google Hybrid tile")
            return nil
        }
        
        print("✅ Downloaded Google Hybrid tile matching live view")
        return tileImage
    }
    
    // MARK: - Get Tile Coordinates
    
    private static func getTileCoordinates(lat: Double, lng: Double, zoom: Int) -> (x: Int, y: Int) {
        let n = pow(2.0, Double(zoom))
        let x = Int((lng + 180.0) / 360.0 * n)
        let latRad = lat * .pi / 180.0
        let y = Int((1.0 - log(tan(latRad) + 1.0 / cos(latRad)) / .pi) / 2.0 * n)
        return (x, y)
    }
}
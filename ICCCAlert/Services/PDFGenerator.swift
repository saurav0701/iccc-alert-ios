import Foundation
import UIKit
import PDFKit
import MapKit
import WebKit
import SwiftUI

class PDFGenerator {
    static let shared = PDFGenerator()
    
    private init() {}
    
    // Generate PDF for a single event
    func generateEventPDF(event: Event, channel: Channel) -> URL? {
        let pdfMetaData = [
            kCGPDFContextCreator: "ICCC Event Manager",
            kCGPDFContextAuthor: "ICCC",
            kCGPDFContextTitle: "Event Report - \(event.typeDisplay ?? "")"
        ]
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = pdfMetaData as [String: Any]
        
        let pageWidth = 8.5 * 72.0
        let pageHeight = 11 * 72.0
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)
        
        let data = renderer.pdfData { context in
            context.beginPage()
            
            let titleFont = UIFont.boldSystemFont(ofSize: 24)
            let headerFont = UIFont.boldSystemFont(ofSize: 16)
            let bodyFont = UIFont.systemFont(ofSize: 14)
            let captionFont = UIFont.systemFont(ofSize: 12)
            
            var yPosition: CGFloat = 40
            
            // Title
            let titleText = "Event Report"
            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: titleFont,
                .foregroundColor: UIColor.black
            ]
            let titleSize = titleText.size(withAttributes: titleAttributes)
            titleText.draw(at: CGPoint(x: (pageWidth - titleSize.width) / 2, y: yPosition), withAttributes: titleAttributes)
            yPosition += titleSize.height + 20
            
            // Separator line
            context.cgContext.setStrokeColor(UIColor.lightGray.cgColor)
            context.cgContext.setLineWidth(1)
            context.cgContext.move(to: CGPoint(x: 40, y: yPosition))
            context.cgContext.addLine(to: CGPoint(x: pageWidth - 40, y: yPosition))
            context.cgContext.strokePath()
            yPosition += 20
            
            // Event Type
            let eventTypeLabel = "Event Type:"
            let eventTypeValue = event.typeDisplay ?? event.type ?? "Unknown"
            yPosition = self.drawLabelValue(label: eventTypeLabel, value: eventTypeValue, 
                                      yPosition: yPosition, pageWidth: pageWidth,
                                      headerFont: headerFont, bodyFont: bodyFont, context: context)
            yPosition += 15
            
            // Location
            let locationLabel = "Location:"
            let locationValue = event.location
            yPosition = self.drawLabelValue(label: locationLabel, value: locationValue,
                                      yPosition: yPosition, pageWidth: pageWidth,
                                      headerFont: headerFont, bodyFont: bodyFont, context: context)
            yPosition += 15
            
            // Area
            let areaLabel = "Area:"
            let areaValue = event.areaDisplay ?? event.area ?? "Unknown"
            yPosition = self.drawLabelValue(label: areaLabel, value: areaValue,
                                      yPosition: yPosition, pageWidth: pageWidth,
                                      headerFont: headerFont, bodyFont: bodyFont, context: context)
            yPosition += 15
            
            // Date & Time
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "MMM dd, yyyy 'at' HH:mm:ss"
            let dateLabel = "Date & Time:"
            let dateValue = dateFormatter.string(from: event.date)
            yPosition = self.drawLabelValue(label: dateLabel, value: dateValue,
                                      yPosition: yPosition, pageWidth: pageWidth,
                                      headerFont: headerFont, bodyFont: bodyFont, context: context)
            yPosition += 15
            
            // GPS specific data
            if event.isGpsEvent {
                if let vehicleNumber = event.vehicleNumber {
                    let vehicleLabel = "Vehicle Number:"
                    yPosition = self.drawLabelValue(label: vehicleLabel, value: vehicleNumber,
                                              yPosition: yPosition, pageWidth: pageWidth,
                                              headerFont: headerFont, bodyFont: bodyFont, context: context)
                    yPosition += 15
                }
                
                if let transporter = event.vehicleTransporter {
                    let transporterLabel = "Transporter:"
                    yPosition = self.drawLabelValue(label: transporterLabel, value: transporter,
                                              yPosition: yPosition, pageWidth: pageWidth,
                                              headerFont: headerFont, bodyFont: bodyFont, context: context)
                    yPosition += 15
                }
                
                if let alertSubType = event.alertSubType {
                    let alertLabel = "Alert Type:"
                    yPosition = self.drawLabelValue(label: alertLabel, value: alertSubType,
                                              yPosition: yPosition, pageWidth: pageWidth,
                                              headerFont: headerFont, bodyFont: bodyFont, context: context)
                    yPosition += 15
                }
                
                if let gpsLoc = event.gpsAlertLocation {
                    let coordsLabel = "Coordinates:"
                    let coordsValue = String(format: "%.6f, %.6f", gpsLoc.lat, gpsLoc.lng)
                    yPosition = self.drawLabelValue(label: coordsLabel, value: coordsValue,
                                              yPosition: yPosition, pageWidth: pageWidth,
                                              headerFont: headerFont, bodyFont: bodyFont, context: context)
                    yPosition += 15
                }
            }
            
            yPosition += 10
            
            // Image section (for camera events) or Map (for GPS events)
            if event.isGpsEvent {
                // GPS Event - Generate map snapshot
                let mapLabel = "Location Map:"
                let mapAttributes: [NSAttributedString.Key: Any] = [
                    .font: headerFont,
                    .foregroundColor: UIColor.black
                ]
                mapLabel.draw(at: CGPoint(x: 40, y: yPosition), withAttributes: mapAttributes)
                yPosition += 25
                
                if let mapImage = self.generateMapSnapshot(for: event) {
                    let maxImageWidth = pageWidth - 80
                    let maxImageHeight: CGFloat = 400
                    
                    let imageSize = mapImage.size
                    let aspectRatio = imageSize.width / imageSize.height
                    
                    var drawWidth = maxImageWidth
                    var drawHeight = drawWidth / aspectRatio
                    
                    if drawHeight > maxImageHeight {
                        drawHeight = maxImageHeight
                        drawWidth = drawHeight * aspectRatio
                    }
                    
                    let imageX = (pageWidth - drawWidth) / 2
                    let imageRect = CGRect(x: imageX, y: yPosition, width: drawWidth, height: drawHeight)
                    
                    mapImage.draw(in: imageRect)
                    yPosition += drawHeight + 20
                } else {
                    let noMapText = "Map not available"
                    let noMapAttributes: [NSAttributedString.Key: Any] = [
                        .font: captionFont,
                        .foregroundColor: UIColor.gray
                    ]
                    noMapText.draw(at: CGPoint(x: 40, y: yPosition), withAttributes: noMapAttributes)
                    yPosition += 30
                }
            } else {
                // Camera Event - Load and display image
                let imageLabel = "Event Image:"
                let imageAttributes: [NSAttributedString.Key: Any] = [
                    .font: headerFont,
                    .foregroundColor: UIColor.black
                ]
                imageLabel.draw(at: CGPoint(x: 40, y: yPosition), withAttributes: imageAttributes)
                yPosition += 25
                
                if let loadedImage = self.loadEventImage(event: event) {
                    let maxImageWidth = pageWidth - 80
                    let maxImageHeight: CGFloat = 400
                    
                    let imageSize = loadedImage.size
                    let aspectRatio = imageSize.width / imageSize.height
                    
                    var drawWidth = maxImageWidth
                    var drawHeight = drawWidth / aspectRatio
                    
                    if drawHeight > maxImageHeight {
                        drawHeight = maxImageHeight
                        drawWidth = drawHeight * aspectRatio
                    }
                    
                    let imageX = (pageWidth - drawWidth) / 2
                    let imageRect = CGRect(x: imageX, y: yPosition, width: drawWidth, height: drawHeight)
                    
                    loadedImage.draw(in: imageRect)
                    yPosition += drawHeight + 20
                } else {
                    let noImageText = "Image not available"
                    let noImageAttributes: [NSAttributedString.Key: Any] = [
                        .font: captionFont,
                        .foregroundColor: UIColor.gray
                    ]
                    noImageText.draw(at: CGPoint(x: 40, y: yPosition), withAttributes: noImageAttributes)
                    yPosition += 30
                }
            }
            
            // Footer
            yPosition = pageHeight - 60
            context.cgContext.setStrokeColor(UIColor.lightGray.cgColor)
            context.cgContext.setLineWidth(1)
            context.cgContext.move(to: CGPoint(x: 40, y: yPosition))
            context.cgContext.addLine(to: CGPoint(x: pageWidth - 40, y: yPosition))
            context.cgContext.strokePath()
            yPosition += 10
            
            let footerText = "Generated by ICCC Event Manager on \(dateFormatter.string(from: Date()))"
            let footerAttributes: [NSAttributedString.Key: Any] = [
                .font: captionFont,
                .foregroundColor: UIColor.gray
            ]
            let footerSize = footerText.size(withAttributes: footerAttributes)
            footerText.draw(at: CGPoint(x: (pageWidth - footerSize.width) / 2, y: yPosition), withAttributes: footerAttributes)
        }
        
        let fileName = "Event_\(event.id ?? UUID().uuidString)_\(Int(Date().timeIntervalSince1970)).pdf"
        
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("❌ Could not access Documents directory")
            return nil
        }
        
        let fileURL = documentsPath.appendingPathComponent(fileName)
        
        do {
            try data.write(to: fileURL)
            print("✅ PDF saved to: \(fileURL.path)")
            return fileURL
        } catch {
            print("❌ Error saving PDF: \(error.localizedDescription)")
            return nil
        }
    }
    
// Generate PDF for multiple events (channel events)
func generateChannelEventsPDF(events: [Event], channel: Channel) -> URL? {
    guard !events.isEmpty else {
        print("❌ No events to generate PDF")
        return nil
    }
    
    print("📄 Generating PDF for \(events.count) events...")
    
    let pdfMetaData = [
        kCGPDFContextCreator: "ICCC Event Manager",
        kCGPDFContextAuthor: "ICCC",
        kCGPDFContextTitle: "Events Report - \(channel.eventTypeDisplay)"
    ]
    let format = UIGraphicsPDFRendererFormat()
    format.documentInfo = pdfMetaData as [String: Any]
    
    let pageWidth = 8.5 * 72.0
    let pageHeight = 11 * 72.0
    let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
    let margin: CGFloat = 40
    let contentWidth = pageWidth - (2 * margin)
    
    let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)
    
    let data = renderer.pdfData { context in
        let titleFont = UIFont.boldSystemFont(ofSize: 24)
        let headerFont = UIFont.boldSystemFont(ofSize: 16)
        let bodyFont = UIFont.systemFont(ofSize: 14)
        let captionFont = UIFont.systemFont(ofSize: 12)
        let smallFont = UIFont.systemFont(ofSize: 10)
        
        // First page - Summary
        context.beginPage()
        var yPosition: CGFloat = 40
        
        let titleText = "Events Report"
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: UIColor.black
        ]
        let titleSize = titleText.size(withAttributes: titleAttributes)
        titleText.draw(at: CGPoint(x: (pageWidth - titleSize.width) / 2, y: yPosition), withAttributes: titleAttributes)
        yPosition += titleSize.height + 10
        
        let subtitleText = "\(channel.eventTypeDisplay) - \(channel.areaDisplay)"
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: headerFont,
            .foregroundColor: UIColor.darkGray
        ]
        let subtitleSize = subtitleText.size(withAttributes: subtitleAttributes)
        subtitleText.draw(at: CGPoint(x: (pageWidth - subtitleSize.width) / 2, y: yPosition), withAttributes: subtitleAttributes)
        yPosition += subtitleSize.height + 20
        
        // Separator
        context.cgContext.setStrokeColor(UIColor.lightGray.cgColor)
        context.cgContext.setLineWidth(1)
        context.cgContext.move(to: CGPoint(x: margin, y: yPosition))
        context.cgContext.addLine(to: CGPoint(x: pageWidth - margin, y: yPosition))
        context.cgContext.strokePath()
        yPosition += 20
        
        // Summary info
        let summaryLabel = "Total Events:"
        let summaryValue = "\(events.count)"
        yPosition = self.drawLabelValue(label: summaryLabel, value: summaryValue,
                                  yPosition: yPosition, pageWidth: pageWidth,
                                  headerFont: headerFont, bodyFont: bodyFont, context: context)
        yPosition += 15
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM dd, yyyy"
        let reportDateLabel = "Report Generated:"
        let reportDateValue = dateFormatter.string(from: Date())
        yPosition = self.drawLabelValue(label: reportDateLabel, value: reportDateValue,
                                  yPosition: yPosition, pageWidth: pageWidth,
                                  headerFont: headerFont, bodyFont: bodyFont, context: context)
        yPosition += 30
        
        // ✅ NEW: Process events in pairs (2 per page)
        var eventIndex = 0
        
        while eventIndex < events.count {
            // Start new page for events
            if eventIndex > 0 {
                context.beginPage()
            } else if yPosition > margin + 100 {
                // Continue on summary page if space available
                context.beginPage()
            }
            
            yPosition = margin
            
            // ✅ Process 2 events per page
            let eventsThisPage = min(2, events.count - eventIndex)
            let availableHeight = pageHeight - (2 * margin) - 60 // Reserve 60 for footer
            let eventHeight = availableHeight / 2 // Split page in half
            
            for i in 0..<eventsThisPage {
                let event = events[eventIndex + i]
                let isFirstEvent = (i == 0)
                let startY = margin + (CGFloat(i) * eventHeight)
                
                yPosition = startY
                
                // Draw event in allocated space
                yPosition = self.drawEventInBox(
                    event: event,
                    eventNumber: eventIndex + i + 1,
                    startY: yPosition,
                    maxHeight: eventHeight - 10, // 10pt padding between events
                    pageWidth: pageWidth,
                    margin: margin,
                    contentWidth: contentWidth,
                    headerFont: headerFont,
                    bodyFont: bodyFont,
                    smallFont: smallFont,
                    captionFont: captionFont,
                    context: context
                )
                
                // Draw separator between events (not after last event on page)
                if i < eventsThisPage - 1 {
                    let separatorY = startY + eventHeight - 5
                    context.cgContext.setStrokeColor(UIColor.lightGray.cgColor)
                    context.cgContext.setLineWidth(1)
                    context.cgContext.setLineDash(phase: 0, lengths: [5, 3])
                    context.cgContext.move(to: CGPoint(x: margin, y: separatorY))
                    context.cgContext.addLine(to: CGPoint(x: pageWidth - margin, y: separatorY))
                    context.cgContext.strokePath()
                    context.cgContext.setLineDash(phase: 0, lengths: [])
                }
            }
            
            // Draw footer on this page
            self.drawFooter(
                pageWidth: pageWidth,
                pageHeight: pageHeight,
                margin: margin,
                captionFont: captionFont,
                context: context
            )
            
            eventIndex += eventsThisPage
        }
    }
    
    let fileName = "Events_\(channel.eventType)_\(Int(Date().timeIntervalSince1970)).pdf"
    
    guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
        print("❌ Could not access Documents directory")
        return nil
    }
    
    let fileURL = documentsPath.appendingPathComponent(fileName)
    
    do {
        try data.write(to: fileURL)
        print("✅ PDF saved successfully to: \(fileURL.path)")
        print("📁 File size: \(data.count) bytes")
        return fileURL
    } catch {
        print("❌ Error saving PDF: \(error.localizedDescription)")
        return nil
    }
}

// MARK: - Helper: Draw Event in Allocated Box

private func drawEventInBox(
    event: Event,
    eventNumber: Int,
    startY: CGFloat,
    maxHeight: CGFloat,
    pageWidth: CGFloat,
    margin: CGFloat,
    contentWidth: CGFloat,
    headerFont: UIFont,
    bodyFont: UIFont,
    smallFont: UIFont,
    captionFont: UIFont,
    context: UIGraphicsPDFRendererContext
) -> CGFloat {
    var yPosition = startY
    
    // Event header
    let eventTitle = "Event #\(eventNumber)"
    let eventTitleAttributes: [NSAttributedString.Key: Any] = [
        .font: headerFont,
        .foregroundColor: UIColor.black
    ]
    eventTitle.draw(at: CGPoint(x: margin, y: yPosition), withAttributes: eventTitleAttributes)
    yPosition += 25
    
    // Event details
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "MMM dd, yyyy 'at' HH:mm:ss"
    let eventDate = dateFormatter.string(from: event.date)
    yPosition = self.drawLabelValue(label: "Time:", value: eventDate,
                              yPosition: yPosition, pageWidth: pageWidth,
                              headerFont: bodyFont, bodyFont: smallFont, context: context)
    yPosition += 10
    
    let eventType = event.typeDisplay ?? event.type ?? "Unknown"
    yPosition = self.drawLabelValue(label: "Type:", value: eventType,
                              yPosition: yPosition, pageWidth: pageWidth,
                              headerFont: bodyFont, bodyFont: smallFont, context: context)
    yPosition += 10
    
    yPosition = self.drawLabelValue(label: "Location:", value: event.location,
                              yPosition: yPosition, pageWidth: pageWidth,
                              headerFont: bodyFont, bodyFont: smallFont, context: context)
    yPosition += 12
    
    // GPS event details
    if event.isGpsEvent {
        if let vehicleNumber = event.vehicleNumber {
            yPosition = self.drawLabelValue(label: "Vehicle:", value: vehicleNumber,
                                      yPosition: yPosition, pageWidth: pageWidth,
                                      headerFont: bodyFont, bodyFont: smallFont, context: context)
            yPosition += 10
        }
        
        if let gpsLoc = event.gpsAlertLocation {
            let coords = String(format: "%.6f, %.6f", gpsLoc.lat, gpsLoc.lng)
            yPosition = self.drawLabelValue(label: "Coordinates:", value: coords,
                                      yPosition: yPosition, pageWidth: pageWidth,
                                      headerFont: bodyFont, bodyFont: smallFont, context: context)
            yPosition += 12
        }
        
        // Add map snapshot for GPS events
        if let mapImage = self.generateMapSnapshot(for: event) {
            let availableImageHeight = (startY + maxHeight) - yPosition - 30
            let maxImageWidth = contentWidth
            let maxImageHeight = min(availableImageHeight, 200) // Cap at 200
            
            let imageSize = mapImage.size
            let aspectRatio = imageSize.width / imageSize.height
            
            var drawWidth = maxImageWidth
            var drawHeight = drawWidth / aspectRatio
            
            if drawHeight > maxImageHeight {
                drawHeight = maxImageHeight
                drawWidth = drawHeight * aspectRatio
            }
            
            let imageX = (pageWidth - drawWidth) / 2
            let imageRect = CGRect(x: imageX, y: yPosition, width: drawWidth, height: drawHeight)
            
            mapImage.draw(in: imageRect)
            yPosition += drawHeight + 10
        }
    } else {
        // Add image for camera events
        if let image = self.loadEventImage(event: event) {
            let availableImageHeight = (startY + maxHeight) - yPosition - 30
            let maxImageWidth = contentWidth
            let maxImageHeight = min(availableImageHeight, 200) // Cap at 200
            
            let imageSize = image.size
            let aspectRatio = imageSize.width / imageSize.height
            
            var drawWidth = maxImageWidth
            var drawHeight = drawWidth / aspectRatio
            
            if drawHeight > maxImageHeight {
                drawHeight = maxImageHeight
                drawWidth = drawHeight * aspectRatio
            }
            
            let imageX = (pageWidth - drawWidth) / 2
            let imageRect = CGRect(x: imageX, y: yPosition, width: drawWidth, height: drawHeight)
            
            image.draw(in: imageRect)
            yPosition += drawHeight + 10
        }
    }
    
    return yPosition
}

// MARK: - Helper: Draw Footer

private func drawFooter(
    pageWidth: CGFloat,
    pageHeight: CGFloat,
    margin: CGFloat,
    captionFont: UIFont,
    context: UIGraphicsPDFRendererContext
) {
    let footerY = pageHeight - 50
    
    context.cgContext.setStrokeColor(UIColor.lightGray.cgColor)
    context.cgContext.setLineWidth(1)
    context.cgContext.move(to: CGPoint(x: margin, y: footerY))
    context.cgContext.addLine(to: CGPoint(x: pageWidth - margin, y: footerY))
    context.cgContext.strokePath()
    
    let footerText = "Generated by ICCC Event Manager"
    let footerAttributes: [NSAttributedString.Key: Any] = [
        .font: captionFont,
        .foregroundColor: UIColor.gray
    ]
    let footerSize = footerText.size(withAttributes: footerAttributes)
    footerText.draw(at: CGPoint(x: (pageWidth - footerSize.width) / 2, y: footerY + 10), withAttributes: footerAttributes)
}

private func generateMapSnapshot(for event: Event) -> UIImage? {
    guard let alertLoc = event.gpsAlertLocation else {
        print("⚠️ No GPS location for event")
        return nil
    }
    
    let mapSize = CGSize(width: 1200, height: 900) // Higher resolution for PDF
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
        // For tamper without geofence, add padding
        let padding = 0.002
        coordinates.append(CLLocationCoordinate2D(latitude: alertLoc.lat + padding, longitude: alertLoc.lng))
        coordinates.append(CLLocationCoordinate2D(latitude: alertLoc.lat - padding, longitude: alertLoc.lng))
    }
    
    options.region = MKCoordinateRegion(center: center, span: span)
    options.size = mapSize
    options.scale = UIScreen.main.scale
    
    // ✅ USE GOOGLE HYBRID TILES (same as live app)
    let googleTileOverlay = GoogleHybridTileOverlay()
    googleTileOverlay.canReplaceMapContent = true
    options.mapType = .standard // We'll overlay on standard
    
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
        
        // Draw on the snapshot
        UIGraphicsBeginImageContextWithOptions(mapSize, true, 0)
        snapshot.image.draw(at: .zero)
        
        let context = UIGraphicsGetCurrentContext()
        
        // ✅ Draw RED PIN at alert location (same as live app)
        let pinPoint = snapshot.point(for: center)
        
        // Draw red pin with white center
        context?.setFillColor(UIColor.red.cgColor)
        context?.fillEllipse(in: CGRect(x: pinPoint.x - 15, y: pinPoint.y - 15, width: 30, height: 30))
        context?.setFillColor(UIColor.white.cgColor)
        context?.fillEllipse(in: CGRect(x: pinPoint.x - 8, y: pinPoint.y - 8, width: 16, height: 16))
        
        // ✅ Draw coordinates text below pin (always shown)
        let coordText = String(format: "%.6f, %.6f", alertLoc.lat, alertLoc.lng)
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 16),
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
        
        // Draw background for text
        context?.setFillColor(UIColor.black.withAlphaComponent(0.6).cgColor)
        let bgRect = textRect.insetBy(dx: -8, dy: -4)
        context?.fill(bgRect)
        
        coordText.draw(in: textRect, withAttributes: textAttributes)
        
        // Draw geofence if available
        if let geofence = event.geofenceInfo,
           let geojson = geofence.geojson,
           let coords = geojson.coordinatesArray {
            
            // Get color from attributes (same as live app)
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
        
        resultImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
    }
    
    _ = semaphore.wait(timeout: .now() + 15) // Increased timeout
    
    if let image = resultImage {
        print("✅ Map snapshot generated with coordinates overlay")
    } else {
        print("⚠️ Failed to generate map snapshot")
    }
    
    return resultImage
}
    
    private func loadEventImage(event: Event) -> UIImage? {
        guard let eventId = event.id, let area = event.area else {
            print("⚠️ Event missing ID or area")
            return nil
        }
        
        // Try to get cached image from EventImageLoader
        if let cachedImage = EventImageLoader.shared.getCachedImage(area: area, eventId: eventId) {
            print("✅ Found cached image for event \(eventId)")
            return cachedImage
        }
        
        // Try to load from disk cache synchronously
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let fileURL = cacheDir.appendingPathComponent("event_\(eventId).jpg")
        
        if let data = try? Data(contentsOf: fileURL),
           let image = UIImage(data: data) {
            print("✅ Loaded image from disk for event \(eventId)")
            return image
        }
        
        // Try to download image synchronously (last resort)
        let imageUrl = EventImageLoader.shared.buildImageUrl(area: area, eventId: eventId)
        
        if let url = URL(string: imageUrl),
           let data = try? Data(contentsOf: url),
           let image = UIImage(data: data) {
            print("✅ Downloaded image for event \(eventId)")
            
            // Cache it for next time
            try? data.write(to: fileURL)
            
            return image
        }
        
        print("⚠️ No image available for event \(eventId)")
        return nil
    }
    
    // MARK: - Helper: Draw Label-Value Pairs
    
    private func drawLabelValue(label: String, value: String, yPosition: CGFloat, 
                                pageWidth: CGFloat, headerFont: UIFont, bodyFont: UIFont,
                                context: UIGraphicsPDFRendererContext) -> CGFloat {
        var currentY = yPosition
        
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: headerFont,
            .foregroundColor: UIColor.black
        ]
        label.draw(at: CGPoint(x: 40, y: currentY), withAttributes: labelAttributes)
        
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: UIColor.darkGray
        ]
        
        let maxWidth = pageWidth - 220
        let valueRect = CGRect(x: 200, y: currentY, width: maxWidth, height: 1000)
        let boundingRect = value.boundingRect(with: CGSize(width: maxWidth, height: 1000),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading],
                                             attributes: valueAttributes,
                                             context: nil)
        
        value.draw(in: valueRect, withAttributes: valueAttributes)
        currentY += boundingRect.height
        
        return currentY
    }
    
    // MARK: - Share PDF via WhatsApp
    
    func sharePDFViaWhatsApp(pdfURL: URL, from viewController: UIViewController) {
        let whatsappURL = URL(string: "whatsapp://app")!
        
        if UIApplication.shared.canOpenURL(whatsappURL) {
            let activityViewController = UIActivityViewController(
                activityItems: [pdfURL],
                applicationActivities: nil
            )
            
            activityViewController.excludedActivityTypes = [
                .addToReadingList,
                .assignToContact,
                .print
            ]
            
            if let popoverController = activityViewController.popoverPresentationController {
                popoverController.sourceView = viewController.view
                popoverController.sourceRect = CGRect(x: viewController.view.bounds.midX,
                                                     y: viewController.view.bounds.midY,
                                                     width: 0, height: 0)
                popoverController.permittedArrowDirections = []
            }
            
            viewController.present(activityViewController, animated: true)
        } else {
            let alert = UIAlertController(
                title: "WhatsApp Not Found",
                message: "Please install WhatsApp to share via WhatsApp",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            viewController.present(alert, animated: true)
        }
    }
}

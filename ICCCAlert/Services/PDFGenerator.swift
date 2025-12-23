import Foundation
import UIKit
import PDFKit
import MapKit

class PDFGenerator {
    static let shared = PDFGenerator()
    
    private init() {}
    
    // MARK: - Generate PDF for Multiple Events (Table Format)
    
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
        
        // A4 Landscape dimensions for better table view
        let pageWidth = 11 * 72.0  // 792 points
        let pageHeight = 8.5 * 72.0  // 612 points
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        let margin: CGFloat = 30
        
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)
        
        let data = renderer.pdfData { context in
            // Start first page
            context.beginPage()
            
            var currentPage = 1
            let eventsPerPage = 3  // 3 events per page in landscape
            
            for (index, event) in events.enumerated() {
                // Draw page header on each new page
                if index % eventsPerPage == 0 {
                    if index > 0 {
                        // Draw footer before starting new page
                        PDFLayoutHelper.drawFooter(
                            pageNumber: currentPage,
                            totalPages: (events.count + eventsPerPage - 1) / eventsPerPage,
                            pageWidth: pageWidth,
                            pageHeight: pageHeight,
                            margin: margin,
                            context: context
                        )
                        
                        context.beginPage()
                        currentPage += 1
                    }
                    
                    PDFLayoutHelper.drawHeader(
                        channel: channel,
                        totalEvents: events.count,
                        pageWidth: pageWidth,
                        margin: margin,
                        context: context
                    )
                }
                
                // Calculate position for this event
                let eventIndex = index % eventsPerPage
                let startY = 120 + CGFloat(eventIndex) * 150  // Header is 120pt, each event row is 150pt
                
                // Draw event row in table format
                drawEventTableRow(
                    event: event,
                    eventNumber: index + 1,
                    startY: startY,
                    pageWidth: pageWidth,
                    margin: margin,
                    context: context
                )
                
                // Draw separator line between events (except last on page)
                if eventIndex < eventsPerPage - 1 && index < events.count - 1 {
                    let separatorY = startY + 145
                    context.cgContext.setStrokeColor(UIColor.lightGray.cgColor)
                    context.cgContext.setLineWidth(0.5)
                    context.cgContext.move(to: CGPoint(x: margin, y: separatorY))
                    context.cgContext.addLine(to: CGPoint(x: pageWidth - margin, y: separatorY))
                    context.cgContext.strokePath()
                }
            }
            
            // Draw footer on last page
            PDFLayoutHelper.drawFooter(
                pageNumber: currentPage,
                totalPages: (events.count + eventsPerPage - 1) / eventsPerPage,
                pageWidth: pageWidth,
                pageHeight: pageHeight,
                margin: margin,
                context: context
            )
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
    
    // MARK: - Draw Event Table Row
    
    private func drawEventTableRow(
        event: Event,
        eventNumber: Int,
        startY: CGFloat,
        pageWidth: CGFloat,
        margin: CGFloat,
        context: UIGraphicsPDFRendererContext
    ) {
        let contentWidth = pageWidth - (2 * margin)
        
        // Column widths (landscape layout)
        let col1Width: CGFloat = 50   // Event #
        let col2Width: CGFloat = 120  // Type
        let col3Width: CGFloat = 200  // Location
        let col4Width: CGFloat = 120  // Timestamp
        let col5Width: CGFloat = contentWidth - col1Width - col2Width - col3Width - col4Width  // Image/Map
        
        var currentX = margin
        let rowHeight: CGFloat = 140
        
        // Fonts
        let headerFont = UIFont.boldSystemFont(ofSize: 11)
        let bodyFont = UIFont.systemFont(ofSize: 10)
        let smallFont = UIFont.systemFont(ofSize: 9)
        
        // Draw background for row
        context.cgContext.setFillColor(UIColor.systemGray6.cgColor)
        context.cgContext.fill(CGRect(x: margin, y: startY, width: contentWidth, height: rowHeight))
        
        // Column 1: Event Number
        let numberText = "#\(eventNumber)"
        let numberAttributes: [NSAttributedString.Key: Any] = [
            .font: headerFont,
            .foregroundColor: UIColor.black
        ]
        let numberSize = numberText.size(withAttributes: numberAttributes)
        numberText.draw(
            at: CGPoint(x: currentX + (col1Width - numberSize.width) / 2, y: startY + (rowHeight - numberSize.height) / 2),
            withAttributes: numberAttributes
        )
        currentX += col1Width
        
        // Vertical separator
        PDFLayoutHelper.drawVerticalLine(x: currentX, y: startY, height: rowHeight, context: context)
        currentX += 5
        
        // Column 2: Event Type
        let eventType = event.typeDisplay ?? event.type ?? "Unknown"
        let typeAttributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: UIColor.black
        ]
        let typeRect = CGRect(x: currentX, y: startY + 10, width: col2Width - 10, height: rowHeight - 20)
        eventType.draw(in: typeRect, withAttributes: typeAttributes)
        
        // Show vehicle number for GPS events
        if event.isGpsEvent, let vehicle = event.vehicleNumber {
            let vehicleAttributes: [NSAttributedString.Key: Any] = [
                .font: smallFont,
                .foregroundColor: UIColor.darkGray
            ]
            let vehicleRect = CGRect(x: currentX, y: startY + 35, width: col2Width - 10, height: 40)
            "Vehicle: \(vehicle)".draw(in: vehicleRect, withAttributes: vehicleAttributes)
        }
        
        currentX += col2Width
        
        // Vertical separator
        PDFLayoutHelper.drawVerticalLine(x: currentX, y: startY, height: rowHeight, context: context)
        currentX += 5
        
        // Column 3: Location
        let locationAttributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: UIColor.darkGray
        ]
        let locationRect = CGRect(x: currentX, y: startY + 10, width: col3Width - 10, height: rowHeight - 20)
        event.location.draw(in: locationRect, withAttributes: locationAttributes)
        
        // Show coordinates for GPS events
        if event.isGpsEvent, let gpsLoc = event.gpsAlertLocation {
            let coordsText = String(format: "%.6f, %.6f", gpsLoc.lat, gpsLoc.lng)
            let coordsAttributes: [NSAttributedString.Key: Any] = [
                .font: smallFont,
                .foregroundColor: UIColor.systemBlue
            ]
            let coordsRect = CGRect(x: currentX, y: startY + 55, width: col3Width - 10, height: 40)
            coordsText.draw(in: coordsRect, withAttributes: coordsAttributes)
        }
        
        currentX += col3Width
        
        // Vertical separator
        PDFLayoutHelper.drawVerticalLine(x: currentX, y: startY, height: rowHeight, context: context)
        currentX += 5
        
        // Column 4: Timestamp
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM dd, yyyy"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"
        
        let dateText = dateFormatter.string(from: event.date)
        let timeText = timeFormatter.string(from: event.date)
        
        let dateAttributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: UIColor.black
        ]
        let timeAttributes: [NSAttributedString.Key: Any] = [
            .font: smallFont,
            .foregroundColor: UIColor.darkGray
        ]
        
        dateText.draw(at: CGPoint(x: currentX, y: startY + 40), withAttributes: dateAttributes)
        timeText.draw(at: CGPoint(x: currentX, y: startY + 60), withAttributes: timeAttributes)
        
        currentX += col4Width
        
        // Vertical separator
        PDFLayoutHelper.drawVerticalLine(x: currentX, y: startY, height: rowHeight, context: context)
        currentX += 5
        
        // Column 5: Image/Map
        let imageRect = CGRect(x: currentX, y: startY + 5, width: col5Width - 10, height: rowHeight - 10)
        
        if event.isGpsEvent {
            // Generate map snapshot matching live view EXACTLY
            if let mapImage = PDFMapRenderer.generateMapSnapshot(for: event) {
                mapImage.draw(in: imageRect)
            } else {
                // Placeholder
                context.cgContext.setFillColor(UIColor.systemGray5.cgColor)
                context.cgContext.fill(imageRect)
                
                let placeholderText = "Map unavailable"
                let placeholderAttributes: [NSAttributedString.Key: Any] = [
                    .font: smallFont,
                    .foregroundColor: UIColor.gray
                ]
                let textSize = placeholderText.size(withAttributes: placeholderAttributes)
                placeholderText.draw(
                    at: CGPoint(
                        x: imageRect.midX - textSize.width / 2,
                        y: imageRect.midY - textSize.height / 2
                    ),
                    withAttributes: placeholderAttributes
                )
            }
        } else {
            // Load camera event image
            if let image = loadEventImage(event: event) {
                // Aspect fit
                let imageSize = image.size
                let aspectRatio = imageSize.width / imageSize.height
                let rectAspect = imageRect.width / imageRect.height
                
                var drawRect = imageRect
                if aspectRatio > rectAspect {
                    // Image is wider
                    let newHeight = imageRect.width / aspectRatio
                    drawRect.origin.y += (imageRect.height - newHeight) / 2
                    drawRect.size.height = newHeight
                } else {
                    // Image is taller
                    let newWidth = imageRect.height * aspectRatio
                    drawRect.origin.x += (imageRect.width - newWidth) / 2
                    drawRect.size.width = newWidth
                }
                
                image.draw(in: drawRect)
            } else {
                // Placeholder
                context.cgContext.setFillColor(UIColor.systemGray5.cgColor)
                context.cgContext.fill(imageRect)
                
                let placeholderText = "Image unavailable"
                let placeholderAttributes: [NSAttributedString.Key: Any] = [
                    .font: smallFont,
                    .foregroundColor: UIColor.gray
                ]
                let textSize = placeholderText.size(withAttributes: placeholderAttributes)
                placeholderText.draw(
                    at: CGPoint(
                        x: imageRect.midX - textSize.width / 2,
                        y: imageRect.midY - textSize.height / 2
                    ),
                    withAttributes: placeholderAttributes
                )
            }
        }
        
        // Draw border around entire row
        context.cgContext.setStrokeColor(UIColor.lightGray.cgColor)
        context.cgContext.setLineWidth(1.0)
        context.cgContext.stroke(CGRect(x: margin, y: startY, width: contentWidth, height: rowHeight))
    }
    
    // MARK: - Load Event Image
    
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
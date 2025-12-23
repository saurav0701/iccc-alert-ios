import Foundation
import UIKit
import PDFKit

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
            
            // Image section (for camera events only)
            if !event.isGpsEvent {
                let imageLabel = "Event Image:"
                let imageAttributes: [NSAttributedString.Key: Any] = [
                    .font: headerFont,
                    .foregroundColor: UIColor.black
                ]
                imageLabel.draw(at: CGPoint(x: 40, y: yPosition), withAttributes: imageAttributes)
                yPosition += 25
                
                // Try to load image from EventImageLoader
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
        
        // Save to Documents directory (not temporary)
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
            context.cgContext.move(to: CGPoint(x: 40, y: yPosition))
            context.cgContext.addLine(to: CGPoint(x: pageWidth - 40, y: yPosition))
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
            
            // Event details on subsequent pages
            for (index, event) in events.enumerated() {
                if yPosition > pageHeight - 150 {
                    context.beginPage()
                    yPosition = 40
                }
                
                // Event header
                let eventTitle = "Event #\(index + 1)"
                let eventTitleAttributes: [NSAttributedString.Key: Any] = [
                    .font: headerFont,
                    .foregroundColor: UIColor.black
                ]
                eventTitle.draw(at: CGPoint(x: 40, y: yPosition), withAttributes: eventTitleAttributes)
                yPosition += 25
                
                // Event details
                dateFormatter.dateFormat = "MMM dd, yyyy 'at' HH:mm:ss"
                let eventDate = dateFormatter.string(from: event.date)
                yPosition = self.drawLabelValue(label: "Time:", value: eventDate,
                                          yPosition: yPosition, pageWidth: pageWidth,
                                          headerFont: bodyFont, bodyFont: smallFont, context: context)
                yPosition += 12
                
                let eventType = event.typeDisplay ?? event.type ?? "Unknown"
                yPosition = self.drawLabelValue(label: "Type:", value: eventType,
                                          yPosition: yPosition, pageWidth: pageWidth,
                                          headerFont: bodyFont, bodyFont: smallFont, context: context)
                yPosition += 12
                
                yPosition = self.drawLabelValue(label: "Location:", value: event.location,
                                          yPosition: yPosition, pageWidth: pageWidth,
                                          headerFont: bodyFont, bodyFont: smallFont, context: context)
                yPosition += 20
                
                // Separator
                context.cgContext.setStrokeColor(UIColor.lightGray.cgColor)
                context.cgContext.setLineWidth(0.5)
                context.cgContext.move(to: CGPoint(x: 40, y: yPosition))
                context.cgContext.addLine(to: CGPoint(x: pageWidth - 40, y: yPosition))
                context.cgContext.strokePath()
                yPosition += 15
            }
            
            // Footer on last page
            if yPosition < pageHeight - 60 {
                yPosition = pageHeight - 60
            } else {
                context.beginPage()
                yPosition = pageHeight - 60
            }
            
            context.cgContext.setStrokeColor(UIColor.lightGray.cgColor)
            context.cgContext.setLineWidth(1)
            context.cgContext.move(to: CGPoint(x: 40, y: yPosition))
            context.cgContext.addLine(to: CGPoint(x: pageWidth - 40, y: yPosition))
            context.cgContext.strokePath()
            yPosition += 10
            
            let footerText = "Generated by ICCC Event Manager"
            let footerAttributes: [NSAttributedString.Key: Any] = [
                .font: captionFont,
                .foregroundColor: UIColor.gray
            ]
            let footerSize = footerText.size(withAttributes: footerAttributes)
            footerText.draw(at: CGPoint(x: (pageWidth - footerSize.width) / 2, y: yPosition), withAttributes: footerAttributes)
        }
        
        // Save to Documents directory
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
    
    // Helper to load event image (safely, won't crash if not available)
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
        
        print("⚠️ No image available for event \(eventId)")
        return nil
    }
    
    // Helper function to draw label-value pairs
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
    
    // Share PDF via WhatsApp
    func sharePDFViaWhatsApp(pdfURL: URL, from viewController: UIViewController) {
        let whatsappURL = URL(string: "whatsapp://app")!
        
        if UIApplication.shared.canOpenURL(whatsappURL) {
            let activityViewController = UIActivityViewController(
                activityItems: [pdfURL],
                applicationActivities: nil
            )
            
            // Exclude irrelevant activities
            activityViewController.excludedActivityTypes = [
                .addToReadingList,
                .assignToContact,
                .print
            ]
            
            // For iPad
            if let popoverController = activityViewController.popoverPresentationController {
                popoverController.sourceView = viewController.view
                popoverController.sourceRect = CGRect(x: viewController.view.bounds.midX,
                                                     y: viewController.view.bounds.midY,
                                                     width: 0, height: 0)
                popoverController.permittedArrowDirections = []
            }
            
            viewController.present(activityViewController, animated: true)
        } else {
            // WhatsApp not installed
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
import SwiftUI
import UIKit
import WebKit

// MARK: - Screenshot Manager

class ScreenshotManager: ObservableObject {
    static let shared = ScreenshotManager()
    
    @Published var lastScreenshot: UIImage?
    @Published var showScreenshotPreview = false
    @Published var screenshotSaved = false
    
    private init() {}
    
    // MARK: - Capture Screenshot from WebView
    
    func captureScreenshot(from webView: WKWebView, camera: Camera, completion: @escaping (UIImage?) -> Void) {
        DebugLogger.shared.log("📸 Capturing screenshot...", emoji: "📸", color: .blue)
        
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        
        webView.takeSnapshot(with: config) { [weak self] image, error in
            guard let self = self else { return }
            
            if let error = error {
                DebugLogger.shared.log("❌ Screenshot failed: \(error.localizedDescription)", emoji: "❌", color: .red)
                completion(nil)
                return
            }
            
            if let image = image {
                // Add metadata overlay
                let annotatedImage = self.addMetadata(to: image, camera: camera)
                
                DispatchQueue.main.async {
                    self.lastScreenshot = annotatedImage
                    self.showScreenshotPreview = true
                    DebugLogger.shared.log("✅ Screenshot captured successfully", emoji: "✅", color: .green)
                    completion(annotatedImage)
                }
            } else {
                completion(nil)
            }
        }
    }
    
    // MARK: - Add Metadata Overlay
    
    private func addMetadata(to image: UIImage, camera: Camera) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: image.size)
        
        return renderer.image { context in
            // Draw original image
            image.draw(at: .zero)
            
            // Create gradient overlay at bottom
            let gradientHeight: CGFloat = 80
            let gradientRect = CGRect(
                x: 0,
                y: image.size.height - gradientHeight,
                width: image.size.width,
                height: gradientHeight
            )
            
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    UIColor.clear.cgColor,
                    UIColor.black.withAlphaComponent(0.7).cgColor
                ] as CFArray,
                locations: [0, 1]
            )!
            
            context.cgContext.drawLinearGradient(
                gradient,
                start: CGPoint(x: gradientRect.midX, y: gradientRect.minY),
                end: CGPoint(x: gradientRect.midX, y: gradientRect.maxY),
                options: []
            )
            
            // Add camera info text
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .left
            
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 16),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraphStyle
            ]
            
            let smallAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12),
                .foregroundColor: UIColor.white.withAlphaComponent(0.9),
                .paragraphStyle: paragraphStyle
            ]
            
            let cameraName = camera.displayName as NSString
            let cameraInfo = "\(camera.area) • \(camera.location)" as NSString
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium) as NSString
            
            let padding: CGFloat = 16
            let textY = image.size.height - gradientHeight + 10
            
            cameraName.draw(
                at: CGPoint(x: padding, y: textY),
                withAttributes: attributes
            )
            
            cameraInfo.draw(
                at: CGPoint(x: padding, y: textY + 22),
                withAttributes: smallAttributes
            )
            
            timestamp.draw(
                at: CGPoint(x: padding, y: textY + 40),
                withAttributes: smallAttributes
            )
            
            // Add "LIVE" indicator
            let liveRect = CGRect(
                x: image.size.width - 80,
                y: textY,
                width: 60,
                height: 24
            )
            
            UIColor.red.setFill()
            UIBezierPath(roundedRect: liveRect, cornerRadius: 4).fill()
            
            let liveText = "LIVE" as NSString
            let liveAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 12),
                .foregroundColor: UIColor.white
            ]
            
            let liveTextSize = liveText.size(withAttributes: liveAttributes)
            liveText.draw(
                at: CGPoint(
                    x: liveRect.midX - liveTextSize.width / 2,
                    y: liveRect.midY - liveTextSize.height / 2
                ),
                withAttributes: liveAttributes
            )
        }
    }
    
    // MARK: - Save to Photos
    
    func saveToPhotos(_ image: UIImage, completion: @escaping (Bool) -> Void) {
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        
        DispatchQueue.main.async {
            self.screenshotSaved = true
            DebugLogger.shared.log("💾 Screenshot saved to Photos", emoji: "💾", color: .green)
            completion(true)
            
            // Reset after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.screenshotSaved = false
            }
        }
    }
    
    // MARK: - Share Screenshot
    
    func shareScreenshot(_ image: UIImage, from viewController: UIViewController) {
        let activityVC = UIActivityViewController(
            activityItems: [image],
            applicationActivities: nil
        )
        
        // For iPad
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = viewController.view
            popover.sourceRect = CGRect(
                x: viewController.view.bounds.midX,
                y: viewController.view.bounds.midY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = []
        }
        
        viewController.present(activityVC, animated: true)
        DebugLogger.shared.log("📤 Screenshot share sheet opened", emoji: "📤", color: .blue)
    }
    
    // MARK: - Dismiss Preview
    
    func dismissPreview() {
        showScreenshotPreview = false
        lastScreenshot = nil
    }
}
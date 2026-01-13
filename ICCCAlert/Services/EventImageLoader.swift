import Foundation
import UIKit

/// Helper class for loading event images from area-specific API endpoints
class EventImageLoader {
    static let shared = EventImageLoader()
    
    // Image cache to avoid repeated downloads
    private var imageCache = NSCache<NSString, UIImage>()
    
    // ✅ NEW: Memory pressure tracking
    private var memoryWarningObserver: NSObjectProtocol?
    private var lowMemoryMode = false
    
    private init() {
        setupCache()
        setupMemoryWarningHandler()
    }
    
    private func setupCache() {
        imageCache.countLimit = 100 // Cache up to 100 images
        imageCache.totalCostLimit = 50 * 1024 * 1024 // 50MB cache limit
        
        // ✅ NEW: Set eviction policy
        imageCache.evictsObjectsWithDiscardedContent = true
    }
    
    // ✅ FIXED: Aggressive memory warning handling
    private func setupMemoryWarningHandler() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            
            print("⚠️ MEMORY WARNING - Clearing image cache")
            
            // Enter low memory mode
            self.lowMemoryMode = true
            
            // Clear all cached images
            self.imageCache.removeAllObjects()
            
            // Reduce cache limits temporarily
            self.imageCache.countLimit = 20
            self.imageCache.totalCostLimit = 10 * 1024 * 1024 // 10MB
            
            // Reset to normal after 5 minutes
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
                self.lowMemoryMode = false
                self.imageCache.countLimit = 100
                self.imageCache.totalCostLimit = 50 * 1024 * 1024
                print("✅ Memory pressure relieved - cache limits restored")
            }
        }
    }
    
    /// Get the API URL for a specific area
    func getAreaApiUrl(area: String) -> String {
        let normalizedArea = area.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
        
        switch normalizedArea {
        case "sijua", "katras":
            return "http://a5va.bccliccc.in:10050"
        case "kusunda":
            return "http://a6va.bccliccc.in:5050"
        case "bastacolla":
            return "http://a9va.bccliccc.in:5050"
        case "lodna":
            return "http://a10va.bccliccc.in:5050"
        case "govindpur":
            return "http://103.208.173.163:5050"
        case "barora":
            return "http://103.208.173.131:5050"
        case "block2":
            return "http://103.208.173.147:5050"
        case "pbarea":
            return "http://103.208.173.195:5050"
        case "wjarea":
            return "http://103.208.173.211:5050"
        case "ccwo":
            return "http://103.208.173.179:5050"
        case "cvarea":
            return "http://103.210.88.211:5050"
        case "ej":
            return "http://103.210.88.194:5050"
        default:
            print("⚠️ Unknown area: \(area), using Barora as default")
            return "http://103.208.173.131:5050"
        }
    }
    
    /// Build the full image URL for an event
    func buildImageUrl(area: String, eventId: String) -> String {
        let apiUrl = getAreaApiUrl(area: area)
        return "\(apiUrl)/va/event/?id=\(eventId)"
    }
    
    /// Load image for an event (with caching)
    func loadImage(for event: Event) async throws -> UIImage? {
        guard let eventId = event.id, let area = event.area else {
            throw ImageLoadError.missingEventData
        }
        
        // Check cache first
        let cacheKey = "\(area)_\(eventId)" as NSString
        if let cachedImage = imageCache.object(forKey: cacheKey) {
            print("✅ Image loaded from cache for event: \(eventId)")
            return cachedImage
        }
        
        // Build URL
        let imageUrl = buildImageUrl(area: area, eventId: eventId)
        
        guard let url = URL(string: imageUrl) else {
            throw ImageLoadError.invalidURL(imageUrl)
        }
        
        print("🖼️ Loading image from: \(imageUrl)")
        
        // ✅ FIXED: Configure URLSession with timeout
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        
        let session = URLSession(configuration: configuration)
        
        do {
            // Download image with timeout
            let (data, response) = try await session.data(from: url)
            
            // Check HTTP response
            if let httpResponse = response as? HTTPURLResponse {
                print("📥 Image response status: \(httpResponse.statusCode)")
                
                guard (200...299).contains(httpResponse.statusCode) else {
                    throw ImageLoadError.httpError(httpResponse.statusCode)
                }
            }
            
            // Decode image
            guard let image = UIImage(data: data) else {
                throw ImageLoadError.invalidImageData
            }
            
            // ✅ NEW: Compress large images to save memory
            let optimizedImage = optimizeImage(image)
            
            // Cache the image only if not in low memory mode
            if !lowMemoryMode {
                // Calculate image size for cache cost
                let cost = data.count
                imageCache.setObject(optimizedImage, forKey: cacheKey, cost: cost)
            } else {
                print("⚠️ Low memory mode - skipping cache")
            }
            
            print("✅ Image loaded successfully for event: \(eventId)")
            return optimizedImage
            
        } catch let error as URLError {
            // Handle specific URL errors
            if error.code == .timedOut {
                throw ImageLoadError.timeout
            } else if error.code == .notConnectedToInternet {
                throw ImageLoadError.noInternet
            } else {
                throw ImageLoadError.networkError(error.localizedDescription)
            }
        } catch {
            throw error
        }
    }
    
    // ✅ NEW: Optimize images to reduce memory usage
    private func optimizeImage(_ image: UIImage) -> UIImage {
        // If image is already small, return as-is
        let maxDimension: CGFloat = 1920
        let size = image.size
        
        if size.width <= maxDimension && size.height <= maxDimension {
            return image
        }
        
        // Calculate new size maintaining aspect ratio
        let scale = min(maxDimension / size.width, maxDimension / size.height)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        
        // Resize image
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let resizedImage = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        
        print("📐 Optimized image from \(size.width)x\(size.height) to \(newSize.width)x\(newSize.height)")
        
        return resizedImage
    }
    
    /// Load image with completion handler (for non-async code)
    func loadImage(for event: Event, completion: @escaping (Result<UIImage, Error>) -> Void) {
        Task {
            do {
                if let image = try await loadImage(for: event) {
                    completion(.success(image))
                } else {
                    completion(.failure(ImageLoadError.invalidImageData))
                }
            } catch {
                completion(.failure(error))
            }
        }
    }
    
    /// Clear the image cache
    func clearCache() {
        imageCache.removeAllObjects()
        print("🗑️ Image cache cleared")
    }
    
    /// Get cached image if available
    func getCachedImage(area: String, eventId: String) -> UIImage? {
        let cacheKey = "\(area)_\(eventId)" as NSString
        return imageCache.object(forKey: cacheKey)
    }
    
    /// Get cache statistics
    func getCacheStats() -> (count: Int, totalCost: Int) {
        return (imageCache.countLimit, imageCache.totalCostLimit)
    }
    
    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

// MARK: - Image Load Errors

enum ImageLoadError: LocalizedError {
    case missingEventData
    case invalidURL(String)
    case httpError(Int)
    case invalidImageData
    case timeout
    case noInternet
    case networkError(String)
    
    var errorDescription: String? {
        switch self {
        case .missingEventData:
            return "Event is missing required data (ID or area)"
        case .invalidURL(let url):
            return "Invalid image URL: \(url)"
        case .httpError(let code):
            return "Server error: \(code)"
        case .invalidImageData:
            return "Failed to decode image data"
        case .timeout:
            return "Request timed out. Please check your connection."
        case .noInternet:
            return "No internet connection. Please check your network."
        case .networkError(let message):
            return "Network error: \(message)"
        }
    }
}

// MARK: - SwiftUI AsyncImage Alternative

import SwiftUI

/// SwiftUI view for loading event images with caching
struct CachedEventImage: View {
    let event: Event
    @State private var image: UIImage?
    @State private var isLoading = true
    @State private var error: Error?
    
    var body: some View {
        Group {
            if isLoading {
                ZStack {
                    Rectangle()
                        .fill(Color(.systemGray6))
                    
                    ProgressView()
                }
            } else if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle()
                        .fill(Color(.systemGray6))
                    
                    VStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.system(size: 40))
                            .foregroundColor(.gray)
                        
                        if let error = error as? ImageLoadError {
                            Text(error.errorDescription ?? "Failed to load")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 8)
                        } else {
                            Text("Image unavailable")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .onAppear {
            loadImage()
        }
    }
    
    private func loadImage() {
        Task {
            do {
                let loadedImage = try await EventImageLoader.shared.loadImage(for: event)
                await MainActor.run {
                    self.image = loadedImage
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.error = error
                    self.isLoading = false
                }
                print("❌ Error loading image: \(error.localizedDescription)")
            }
        }
    }
}
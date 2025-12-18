import Foundation
import UIKit

/// Helper class for loading event images from area-specific API endpoints
class EventImageLoader {
    static let shared = EventImageLoader()
    
    // Image cache to avoid repeated downloads
    private var imageCache = NSCache<NSString, UIImage>()
    
    private init() {
        imageCache.countLimit = 100 // Cache up to 100 images
        imageCache.totalCostLimit = 50 * 1024 * 1024 // 50MB cache limit
    }
    
    /// Get the API URL for a specific area
    func getAreaApiUrl(area: String) -> String {
        let normalizedArea = area.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
        
        switch normalizedArea {
        case "barkasayal": return "https://barkasayal.cclai.in/api"
        case "argada": return "https://argada.cclai.in/api"
        case "northkaranpura": return "https://nk.cclai.in/api"
        case "bokarokargali": return "https://bk.cclai.in/api"
        case "kathara": return "https://kathara.cclai.in/api"
        case "giridih": return "https://giridih.cclai.in/api"
        case "amrapali": return "https://amrapali.cclai.in/api"
        case "magadh": return "https://magadh.cclai.in/api"
        case "rajhara": return "https://rajhara.cclai.in/api"
        case "kuju": return "https://kuju.cclai.in/api"
        case "hazaribagh": return "https://hazaribagh.cclai.in/api"
        case "rajrappa": return "https://rajrappa.cclai.in/api"
        case "dhori": return "https://dhori.cclai.in/api"
        case "piparwar": return "https://piparwar.cclai.in/api"
        default:
            print("⚠️ Unknown area: \(area), using default URL")
            return "https://barkasayal.cclai.in/api"
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
        
        // Download image
        let (data, response) = try await URLSession.shared.data(from: url)
        
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
        
        // Cache the image
        imageCache.setObject(image, forKey: cacheKey)
        
        print("✅ Image loaded successfully for event: \(eventId)")
        return image
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
}

// MARK: - Image Load Errors

enum ImageLoadError: LocalizedError {
    case missingEventData
    case invalidURL(String)
    case httpError(Int)
    case invalidImageData
    
    var errorDescription: String? {
        switch self {
        case .missingEventData:
            return "Event is missing required data (ID or area)"
        case .invalidURL(let url):
            return "Invalid image URL: \(url)"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .invalidImageData:
            return "Failed to decode image data"
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
                        
                        if let error = error {
                            Text("Failed to load")
                                .font(.caption)
                                .foregroundColor(.secondary)
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


import Foundation
import UIKit
import Combine

class ImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var isLoading = false
    @Published var error: String?
    
    private var cancellable: AnyCancellable?
    private let cache = NSCache<NSString, UIImage>()
    
    private let logger = DebugLogger.shared
    
    // Get HTTP URL for area (matching Android logic)
    private func getHttpUrlForArea(_ area: String) -> String {
        let normalizedArea = area.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "")
        
        // CCL URLs
        let cclUrls: [String: String] = [
            "barkasayal": "https://barkasayal.cclai.in/api",
            "argada": "https://argada.cclai.in/api",
            "northkaranpura": "https://nk.cclai.in/api",
            "bokarokargali": "https://bk.cclai.in/api",
            "kathara": "https://kathara.cclai.in/api",
            "giridih": "https://giridih.cclai.in/api",
            "amrapali": "https://amrapali.cclai.in/api",
            "magadh": "https://magadh.cclai.in/api",
            "rajhara": "https://rajhara.cclai.in/api",
            "kuju": "https://kuju.cclai.in/api",
            "hazaribagh": "https://hazaribagh.cclai.in/api",
            "rajrappa": "https://rajrappa.cclai.in/api",
            "dhori": "https://dhori.cclai.in/api",
            "piparwar": "https://piparwar.cclai.in/api"
        ]
        
        if let url = cclUrls[normalizedArea] {
            return url
        }
        
        // BCCL URLs (if needed)
        let bcclUrls: [String: String] = [
            "sijua": "http://a5va.bccliccc.in:10050",
            "katras": "http://a5va.bccliccc.in:10050",
            "kusunda": "http://a6va.bccliccc.in:5050",
            "bastacolla": "http://a9va.bccliccc.in:5050",
            "lodna": "http://a10va.bccliccc.in:5050"
        ]
        
        return bcclUrls[normalizedArea] ?? "https://barkasayal.cclai.in/api"
    }
    
    func loadImage(for event: Event) {
        guard let area = event.area, let eventId = event.id else {
            error = "Missing area or event ID"
            return
        }
        
        // Check cache first
        let cacheKey = eventId as NSString
        if let cachedImage = cache.object(forKey: cacheKey) {
            logger.log("IMAGE", "Using cached image for \(eventId)")
            self.image = cachedImage
            return
        }
        
        isLoading = true
        error = nil
        
        let baseUrl = getHttpUrlForArea(area)
        let imageUrl = "\(baseUrl)/va/event/?id=\(eventId)"
        
        logger.log("IMAGE", "Loading image: \(imageUrl)")
        
        guard let url = URL(string: imageUrl) else {
            error = "Invalid URL"
            isLoading = false
            return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .returnCacheDataElseLoad
        
        cancellable = URLSession.shared.dataTaskPublisher(for: request)
            .tryMap { data, response -> UIImage in
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                
                guard httpResponse.statusCode == 200 else {
                    throw URLError(.init(rawValue: httpResponse.statusCode))
                }
                
                guard let image = UIImage(data: data) else {
                    throw URLError(.cannotDecodeContentData)
                }
                
                return image
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] completion in
                self?.isLoading = false
                
                if case .failure(let error) = completion {
                    self?.logger.logError("IMAGE", "Failed to load image: \(error.localizedDescription)")
                    self?.error = error.localizedDescription
                }
            } receiveValue: { [weak self] image in
                guard let self = self else { return }
                
                self.image = image
                self.cache.setObject(image, forKey: cacheKey)
                self.logger.log("IMAGE", "✅ Image loaded and cached for \(eventId)")
            }
    }
    
    func cancel() {
        cancellable?.cancel()
        isLoading = false
    }
}
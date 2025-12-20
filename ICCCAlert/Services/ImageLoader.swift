import Foundation
import UIKit
import Combine

class ImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var isLoading = false
    @Published var error: Error?
    
    private var cancellable: AnyCancellable?
    private var task: URLSessionDataTask?
    
    private let cache = ImageCache.shared
    
    func loadImage(for event: Event) {
        guard let area = event.area,
              let eventId = event.id else {
            return
        }
        
        // Check cache first
        if let cachedImage = cache.get(forKey: eventId) {
            self.image = cachedImage
            return
        }
        
        isLoading = true
        error = nil
        
        let baseURL = "http://192.168.29.69:8890" // CCL
        // let baseURL = "http://192.168.29.69:8890" // BCCL
        let imageURL = "\(baseURL)/images/\(area)/\(eventId).jpg"
        
        guard let url = URL(string: imageURL) else {
            isLoading = false
            error = NSError(domain: "ImageLoader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
            return
        }
        
        task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isLoading = false
                
                if let error = error {
                    self?.error = error
                    return
                }
                
                guard let data = data,
                      let image = UIImage(data: data) else {
                    self?.error = NSError(domain: "ImageLoader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid image data"])
                    return
                }
                
                // Cache the image
                self?.cache.set(image, forKey: eventId)
                self?.image = image
            }
        }
        
        task?.resume()
    }
    
    func cancel() {
        task?.cancel()
        task = nil
        cancellable?.cancel()
        cancellable = nil
    }
}

// MARK: - Image Cache

class ImageCache {
    static let shared = ImageCache()
    
    private let cache = NSCache<NSString, UIImage>()
    
    private init() {
        cache.countLimit = 100
        cache.totalCostLimit = 100 * 1024 * 1024 // 100 MB
    }
    
    func get(forKey key: String) -> UIImage? {
        return cache.object(forKey: key as NSString)
    }
    
    func set(_ image: UIImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
    
    func clear() {
        cache.removeAllObjects()
    }
}
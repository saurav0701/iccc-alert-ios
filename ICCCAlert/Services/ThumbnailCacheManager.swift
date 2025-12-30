import Foundation
import UIKit
import Combine

// MARK: - Simple Thumbnail Cache Manager (No WebRTC - Just Static Images)
class ThumbnailCacheManager: ObservableObject {
    static let shared = ThumbnailCacheManager()
    
    @Published private(set) var thumbnails: [String: UIImage] = [:]
    
    private let cache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private var activeFetches: Set<String> = []
    private let lock = NSLock()
    
    private init() {
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDirectory = paths[0].appendingPathComponent("CameraThumbnails")
        
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        cache.countLimit = 200
        cache.totalCostLimit = 50 * 1024 * 1024 // 50MB
        
        loadCachedThumbnails()
        
        DebugLogger.shared.log("🖼️ ThumbnailCacheManager initialized", emoji: "🖼️", color: .blue)
    }
    
    // MARK: - Get Thumbnail
    
    func getThumbnail(for cameraId: String) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        
        if let cached = cache.object(forKey: cameraId as NSString) {
            return cached
        }
        
        return thumbnails[cameraId]
    }
    
    // MARK: - Fetch Thumbnail (Simple HTTP Snapshot)
    
    func fetchThumbnail(for camera: Camera, force: Bool = false) {
        lock.lock()
        let isAlreadyFetching = activeFetches.contains(camera.id)
        lock.unlock()
        
        if isAlreadyFetching && !force {
            return
        }
        
        if !force && getThumbnail(for: camera.id) != nil {
            return
        }
        
        lock.lock()
        activeFetches.insert(camera.id)
        lock.unlock()
        
        Task {
            await performFetch(for: camera)
        }
    }
    
    @MainActor
    private func performFetch(for camera: Camera) async {
        guard let snapshotURL = getSnapshotURL(for: camera) else {
            DebugLogger.shared.log("⚠️ No snapshot URL for camera: \(camera.id)", emoji: "⚠️", color: .orange)
            removeFetchTask(for: camera.id)
            return
        }
        
        do {
            // Simple HTTP GET request for JPEG snapshot
            let (data, response) = try await URLSession.shared.data(from: URL(string: snapshotURL)!)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let image = UIImage(data: data) else {
                DebugLogger.shared.log("❌ Failed to get snapshot: \(camera.id)", emoji: "❌", color: .red)
                removeFetchTask(for: camera.id)
                return
            }
            
            // Resize to save memory
            let resizedImage = resizeImage(image, targetWidth: 320)
            
            // Save to cache
            saveThumbnail(resizedImage, for: camera.id)
            
            // Update published state
            thumbnails[camera.id] = resizedImage
            cache.setObject(resizedImage, forKey: camera.id as NSString)
            
            DebugLogger.shared.log("✅ Thumbnail captured: \(camera.id)", emoji: "✅", color: .green)
            
        } catch {
            DebugLogger.shared.log("❌ Failed to fetch thumbnail: \(error.localizedDescription)", emoji: "❌", color: .red)
        }
        
        removeFetchTask(for: camera.id)
    }
    
    // MARK: - Snapshot URL Generation
    
    private func getSnapshotURL(for camera: Camera) -> String? {
        // MediaMTX provides snapshot endpoints at /[stream]/snapshot.jpg
        let serverURLs: [Int: String] = [
            5: "http://103.208.173.131:8888",
            6: "http://103.208.173.147:8888",
            7: "http://103.208.173.163:8888",
            8: "http://a5va.bccliccc.in:8888",
            9: "http://a5va.bccliccc.in:8888",
            10: "http://a6va.bccliccc.in:8888",
            11: "http://103.208.173.195:8888",
            12: "http://a9va.bccliccc.in:8888",
            13: "http://a10va.bccliccc.in:8888",
            14: "http://103.210.88.195:8888",
            15: "http://103.210.88.211:8888",
            16: "http://103.208.173.179:8888",
            22: "http://103.208.173.211:8888"
        ]
        
        guard let serverURL = serverURLs[camera.groupId] else {
            return nil
        }
        
        let streamPath = !camera.ip.isEmpty ? camera.ip : camera.id
        return "\(serverURL)/\(streamPath)/snapshot.jpg"
    }
    
    // MARK: - Image Utilities
    
    private func resizeImage(_ image: UIImage, targetWidth: CGFloat) -> UIImage {
        let scale = targetWidth / image.size.width
        let targetHeight = image.size.height * scale
        let targetSize = CGSize(width: targetWidth, height: targetHeight)
        
        UIGraphicsBeginImageContextWithOptions(targetSize, true, 1.0)
        image.draw(in: CGRect(origin: .zero, size: targetSize))
        let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return resizedImage ?? image
    }
    
    // MARK: - Disk Persistence
    
    private func saveThumbnail(_ image: UIImage, for cameraId: String) {
        DispatchQueue.global(qos: .background).async {
            guard let data = image.jpegData(compressionQuality: 0.7) else { return }
            
            let fileURL = self.cacheDirectory.appendingPathComponent("\(cameraId).jpg")
            try? data.write(to: fileURL)
        }
    }
    
    private func loadCachedThumbnails() {
        DispatchQueue.global(qos: .background).async {
            guard let files = try? self.fileManager.contentsOfDirectory(
                at: self.cacheDirectory,
                includingPropertiesForKeys: nil
            ) else {
                return
            }
            
            DispatchQueue.main.async {
                for file in files where file.pathExtension == "jpg" {
                    let cameraId = file.deletingPathExtension().lastPathComponent
                    
                    if let data = try? Data(contentsOf: file),
                       let image = UIImage(data: data) {
                        self.thumbnails[cameraId] = image
                        self.cache.setObject(image, forKey: cameraId as NSString)
                    }
                }
                
                DebugLogger.shared.log("📦 Loaded \(self.thumbnails.count) cached thumbnails", emoji: "📦", color: .blue)
            }
        }
    }
    
    // MARK: - Cleanup
    
    func clearThumbnail(for cameraId: String) {
        lock.lock()
        thumbnails.removeValue(forKey: cameraId)
        cache.removeObject(forKey: cameraId as NSString)
        lock.unlock()
        
        let fileURL = cacheDirectory.appendingPathComponent("\(cameraId).jpg")
        try? fileManager.removeItem(at: fileURL)
    }
    
    func clearAllThumbnails() {
        lock.lock()
        thumbnails.removeAll()
        cache.removeAllObjects()
        activeFetches.removeAll()
        lock.unlock()
        
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        DebugLogger.shared.log("🗑️ All thumbnails cleared", emoji: "🗑️", color: .red)
    }
    
    func clearChannelThumbnails() {
        // Called when user leaves a channel
        lock.lock()
        let keysToRemove = Array(thumbnails.keys)
        lock.unlock()
        
        for key in keysToRemove {
            cache.removeObject(forKey: key as NSString)
        }
        
        DebugLogger.shared.log("🧹 Channel thumbnails cleared from memory", emoji: "🧹", color: .orange)
    }
    
    private func removeFetchTask(for cameraId: String) {
        lock.lock()
        activeFetches.remove(cameraId)
        lock.unlock()
    }
    
    // MARK: - Batch Operations (Throttled)
    
    func prefetchThumbnails(for cameras: [Camera], maxConcurrent: Int = 5) {
        let onlineCameras = cameras.filter { 
            $0.isOnline && getThumbnail(for: $0.id) == nil 
        }
        
        // Take only first N cameras
        let batch = Array(onlineCameras.prefix(maxConcurrent))
        
        // Stagger requests to avoid overwhelming the server
        for (index, camera) in batch.enumerated() {
            let delay = Double(index) * 0.3 // 300ms between requests
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.fetchThumbnail(for: camera)
            }
        }
    }
    
    func prefetchVisibleThumbnails(for cameras: [Camera]) {
        // Only fetch first 10 visible cameras
        let visibleCameras = Array(cameras.prefix(10))
        
        for (index, camera) in visibleCameras.enumerated() {
            if camera.isOnline && getThumbnail(for: camera.id) == nil {
                let delay = Double(index) * 0.5 // 500ms between requests
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self.fetchThumbnail(for: camera)
                }
            }
        }
    }
}
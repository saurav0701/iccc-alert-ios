import Foundation

// MARK: - Paginated Response Model
struct PaginatedCameraResponse: Codable {
    let cameras: [Camera]
    let page: Int
    let pageSize: Int
    let total: Int
    let hasMore: Bool
}

// MARK: - Area Statistics Response Model
struct AreaStatisticsResponse: Codable {
    let total: Int
    let online: Int
    let offline: Int
}

// MARK: - Camera API Service
class CameraAPIService {
    static let shared = CameraAPIService()
    
    private let baseURL = "http://192.168.29.69:8890"
    private let session: URLSession
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }
    
    // MARK: - Paginated Fetch (for backward compatibility)
    func fetchCameras(page: Int, pageSize: Int, completion: @escaping (Result<PaginatedCameraResponse, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/cameras?page=\(page)&pageSize=\(pageSize)") else {
            completion(.failure(NSError(domain: "Invalid URL", code: -1)))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let token = AuthManager.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        DebugLogger.shared.log("📡 Fetching cameras (page \(page), size \(pageSize))", emoji: "📡", color: .blue)
        
        session.dataTask(with: request) { data, response, error in
            if let error = error {
                DebugLogger.shared.log("❌ API error: \(error.localizedDescription)", emoji: "❌", color: .red)
                completion(.failure(error))
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(NSError(domain: "Invalid response", code: -1)))
                return
            }
            
            guard httpResponse.statusCode == 200 else {
                DebugLogger.shared.log("❌ API status \(httpResponse.statusCode)", emoji: "❌", color: .red)
                completion(.failure(NSError(domain: "Server error", code: httpResponse.statusCode)))
                return
            }
            
            guard let data = data else {
                completion(.failure(NSError(domain: "No data", code: -1)))
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let dataDict = json["data"] as? [String: Any],
                   let camerasArray = dataDict["cameras"] as? [[String: Any]],
                   let totalCount = dataDict["total"] as? Int {
                    
                    let camerasData = try JSONSerialization.data(withJSONObject: camerasArray)
                    let cameras = try JSONDecoder().decode([Camera].self, from: camerasData)
                    
                    let currentPage = dataDict["page"] as? Int ?? page
                    let currentPageSize = dataDict["pageSize"] as? Int ?? pageSize
                    let hasMore = cameras.count >= currentPageSize && (currentPage * currentPageSize) < totalCount
                    
                    let response = PaginatedCameraResponse(
                        cameras: cameras,
                        page: currentPage,
                        pageSize: currentPageSize,
                        total: totalCount,
                        hasMore: hasMore
                    )
                    
                    DebugLogger.shared.log("✅ Fetched \(cameras.count) cameras (page \(page))", emoji: "✅", color: .green)
                    completion(.success(response))
                    
                } else {
                    throw NSError(domain: "Invalid response structure", code: -1)
                }
                
            } catch {
                DebugLogger.shared.log("❌ Parse error: \(error)", emoji: "❌", color: .red)
                completion(.failure(error))
            }
        }.resume()
    }
    
    // MARK: - Fetch All Cameras (Fallback for non-paginated backends)
    func fetchAllCameras(completion: @escaping (Result<[Camera], Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/cameras") else {
            completion(.failure(NSError(domain: "Invalid URL", code: -1)))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let token = AuthManager.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        DebugLogger.shared.log("📡 Fetching all cameras via REST API", emoji: "📡", color: .blue)
        
        session.dataTask(with: request) { data, response, error in
            if let error = error {
                DebugLogger.shared.log("❌ API error: \(error.localizedDescription)", emoji: "❌", color: .red)
                completion(.failure(error))
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(NSError(domain: "Invalid response", code: -1)))
                return
            }
            
            guard httpResponse.statusCode == 200 else {
                DebugLogger.shared.log("❌ API returned status \(httpResponse.statusCode)", emoji: "❌", color: .red)
                completion(.failure(NSError(domain: "Server error", code: httpResponse.statusCode)))
                return
            }
            
            guard let data = data else {
                completion(.failure(NSError(domain: "No data", code: -1)))
                return
            }
            
            do {
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                
                guard let dataDict = json?["data"] as? [String: Any],
                      let camerasArray = dataDict["cameras"] as? [[String: Any]] else {
                    throw NSError(domain: "Invalid response structure", code: -1)
                }
                
                let camerasData = try JSONSerialization.data(withJSONObject: camerasArray)
                let cameras = try JSONDecoder().decode([Camera].self, from: camerasData)
                
                DebugLogger.shared.log("✅ Fetched \(cameras.count) cameras via API", emoji: "✅", color: .green)
                
                completion(.success(cameras))
                
            } catch {
                DebugLogger.shared.log("❌ Parse error: \(error)", emoji: "❌", color: .red)
                completion(.failure(error))
            }
        }.resume()
    }
    
    // MARK: - ✅ NEW: Fetch Cameras by Area (for parallel loading)
    func fetchCamerasByArea(_ area: String, completion: @escaping (Result<[Camera], Error>) -> Void) {
        let encodedArea = area.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? area
        
        guard let url = URL(string: "\(baseURL)/cameras/area/\(encodedArea)") else {
            completion(.failure(NSError(domain: "Invalid URL", code: -1)))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let token = AuthManager.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        DebugLogger.shared.log("📡 Fetching cameras for area: \(area)", emoji: "📡", color: .blue)
        
        session.dataTask(with: request) { data, response, error in
            if let error = error {
                DebugLogger.shared.log("❌ Area fetch error (\(area)): \(error.localizedDescription)", emoji: "❌", color: .red)
                completion(.failure(error))
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(NSError(domain: "Invalid response", code: -1)))
                return
            }
            
            guard httpResponse.statusCode == 200 else {
                DebugLogger.shared.log("❌ Area fetch status (\(area)): \(httpResponse.statusCode)", emoji: "❌", color: .red)
                completion(.failure(NSError(domain: "Server error", code: httpResponse.statusCode)))
                return
            }
            
            guard let data = data else {
                completion(.failure(NSError(domain: "No data", code: -1)))
                return
            }
            
            do {
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let dataDict = json?["data"] as? [String: Any],
                      let camerasArray = dataDict["cameras"] as? [[String: Any]] else {
                    throw NSError(domain: "Invalid response", code: -1)
                }
                
                let camerasData = try JSONSerialization.data(withJSONObject: camerasArray)
                let cameras = try JSONDecoder().decode([Camera].self, from: camerasData)
                
                DebugLogger.shared.log("✅ Fetched \(cameras.count) cameras from \(area)", emoji: "✅", color: .green)
                completion(.success(cameras))
                
            } catch {
                DebugLogger.shared.log("❌ Parse error (\(area)): \(error)", emoji: "❌", color: .red)
                completion(.failure(error))
            }
        }.resume()
    }
    
    // MARK: - ✅ NEW: Fetch Camera Statistics (to get area list)
    func fetchCameraStats(completion: @escaping (Result<[String: AreaStatisticsResponse], Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/cameras/stats") else {
            completion(.failure(NSError(domain: "Invalid URL", code: -1)))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let token = AuthManager.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        DebugLogger.shared.log("📊 Fetching camera statistics", emoji: "📊", color: .blue)
        
        session.dataTask(with: request) { data, response, error in
            if let error = error {
                DebugLogger.shared.log("❌ Stats error: \(error.localizedDescription)", emoji: "❌", color: .red)
                completion(.failure(error))
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(NSError(domain: "Invalid response", code: -1)))
                return
            }
            
            guard httpResponse.statusCode == 200 else {
                DebugLogger.shared.log("❌ Stats status \(httpResponse.statusCode)", emoji: "❌", color: .red)
                completion(.failure(NSError(domain: "Server error", code: httpResponse.statusCode)))
                return
            }
            
            guard let data = data else {
                completion(.failure(NSError(domain: "No data", code: -1)))
                return
            }
            
            do {
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                
                guard let dataDict = json?["data"] as? [String: Any],
                      let areaStatsDict = dataDict["areaStats"] as? [String: [String: Int]] else {
                    throw NSError(domain: "Invalid response structure", code: -1)
                }
                
                var areaStats: [String: AreaStatisticsResponse] = [:]
                for (area, stats) in areaStatsDict {
                    areaStats[area] = AreaStatisticsResponse(
                        total: stats["total"] ?? 0,
                        online: stats["online"] ?? 0,
                        offline: stats["offline"] ?? 0
                    )
                }
                
                DebugLogger.shared.log("✅ Fetched stats for \(areaStats.count) areas", emoji: "✅", color: .green)
                completion(.success(areaStats))
                
            } catch {
                DebugLogger.shared.log("❌ Parse error: \(error)", emoji: "❌", color: .red)
                completion(.failure(error))
            }
        }.resume()
    }
    
    // MARK: - Fetch Online Cameras
    func fetchOnlineCameras(completion: @escaping (Result<[Camera], Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/cameras/online") else {
            completion(.failure(NSError(domain: "Invalid URL", code: -1)))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        if let token = AuthManager.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let data = data else {
                completion(.failure(NSError(domain: "No data", code: -1)))
                return
            }
            
            do {
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let dataDict = json?["data"] as? [String: Any],
                      let camerasArray = dataDict["cameras"] as? [[String: Any]] else {
                    throw NSError(domain: "Invalid response", code: -1)
                }
                
                let camerasData = try JSONSerialization.data(withJSONObject: camerasArray)
                let cameras = try JSONDecoder().decode([Camera].self, from: camerasData)
                
                completion(.success(cameras))
                
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
}
import Foundation

// MARK: - Camera API Service (Simplified)
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
    
    // MARK: - ✅ SIMPLIFIED: Fetch ALL Cameras (Single Call)
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
        
        DebugLogger.shared.log("📡 Fetching ALL cameras from backend cache", emoji: "📡", color: .blue)
        
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
                
                let total = dataDict["total"] as? Int ?? cameras.count
                let online = dataDict["online"] as? Int ?? 0
                let cacheAge = dataDict["cacheAge"] as? Double ?? 0
                
                DebugLogger.shared.log("✅ Fetched \(cameras.count) cameras (cache age: \(Int(cacheAge))s)", emoji: "✅", color: .green)
                DebugLogger.shared.log("   Total: \(total), Online: \(online)", emoji: "ℹ️", color: .blue)
                
                completion(.success(cameras))
                
            } catch {
                DebugLogger.shared.log("❌ Parse error: \(error)", emoji: "❌", color: .red)
                completion(.failure(error))
            }
        }.resume()
    }
    
    // MARK: - Fetch Cameras by Area (No Pagination)
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
    
    // MARK: - Fetch Online Cameras (No Pagination)
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
    
    // MARK: - Fetch Camera Statistics
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
    
    // MARK: - Fetch Cache Health
    func fetchCacheHealth(completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/cameras/health") else {
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
            
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataDict = json["data"] as? [String: Any] else {
                completion(.failure(NSError(domain: "Invalid response", code: -1)))
                return
            }
            
            completion(.success(dataDict))
        }.resume()
    }
}

// MARK: - Area Statistics Response Model
struct AreaStatisticsResponse: Codable {
    let total: Int
    let online: Int
    let offline: Int
}
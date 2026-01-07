import Foundation

/// Optional REST API service for manual camera refresh
/// Use this if WebSocket camera updates aren't working
class CameraAPIService {
    static let shared = CameraAPIService()
    
    private let baseURL = "http://192.168.29.69:2222"
    
    private init() {}
    
    // ✅ Fetch all cameras via REST API
    func fetchAllCameras(completion: @escaping (Result<[Camera], Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/cameras") else {
            completion(.failure(NSError(domain: "Invalid URL", code: -1)))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Add auth token if needed
        if let token = AuthManager.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        DebugLogger.shared.log("📡 Fetching cameras via REST API", emoji: "📡", color: .blue)
        
        URLSession.shared.dataTask(with: request) { data, response, error in
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
                // Parse response: { "success": true, "data": { "cameras": [...] } }
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                
                guard let dataDict = json?["data"] as? [String: Any],
                      let camerasArray = dataDict["cameras"] as? [[String: Any]] else {
                    throw NSError(domain: "Invalid response structure", code: -1)
                }
                
                // Convert to JSON data for decoding
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
    
    // ✅ Fetch cameras by area
    func fetchCamerasByArea(_ area: String, completion: @escaping (Result<[Camera], Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/cameras/area/\(area)") else {
            completion(.failure(NSError(domain: "Invalid URL", code: -1)))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        if let token = AuthManager.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        URLSession.shared.dataTask(with: request) { data, response, error in
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
    
    // ✅ Fetch online cameras only
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
        
        URLSession.shared.dataTask(with: request) { data, response, error in
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
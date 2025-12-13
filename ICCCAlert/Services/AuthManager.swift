import Foundation
import UIKit

class AuthManager: ObservableObject {
    static let shared = AuthManager()
    
    @Published var isAuthenticated = false
    @Published var currentUser: User?
    
    private let baseURL = "http://192.168.29.69:19998"
    
    var token: String? {
        return UserDefaults.standard.string(forKey: "auth_token")
    }
    
    private init() {
        checkAuthStatus()
    }
    
    func checkAuthStatus() {
        if let token = UserDefaults.standard.string(forKey: "auth_token"),
           let expiry = UserDefaults.standard.object(forKey: "token_expiry") as? Int64 {
            let now = Int64(Date().timeIntervalSince1970)
            isAuthenticated = expiry > now
            
            if isAuthenticated {
                loadUserData()
            }
        }
    }
    
    // MARK: - Login Flow
    
    func requestOTP(phone: String, completion: @escaping (Bool, String) -> Void) {
        guard let url = URL(string: "\(baseURL)/auth/login/request") else {
            completion(false, "Invalid URL")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = LoginRequest(phone: phone, purpose: "login")
        request.httpBody = try? JSONEncoder().encode(body)
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(false, error.localizedDescription)
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(false, "Invalid response")
                    return
                }
                
                // Parse response for better error messages
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let message = json["message"] as? String {
                    if httpResponse.statusCode == 200 {
                        completion(true, message)
                    } else {
                        let errorMsg = json["error"] as? String ?? message
                        completion(false, errorMsg)
                    }
                } else {
                    completion(false, "Failed to send OTP")
                }
            }
        }.resume()
    }
    
    func verifyOTP(phone: String, otp: String, completion: @escaping (Bool, String) -> Void) {
        guard let url = URL(string: "\(baseURL)/auth/login/verify") else {
            completion(false, "Invalid URL")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-ios"
        let body = OTPVerificationRequest(phone: phone, otp: otp, deviceId: deviceId)
        request.httpBody = try? JSONEncoder().encode(body)
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(false, error.localizedDescription)
                    return
                }
                
                guard let data = data else {
                    completion(false, "No response from server")
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(false, "Invalid response")
                    return
                }
                
                // 🔍 DEBUG: Print the raw response
                if let jsonString = String(data: data, encoding: .utf8) {
                    print("🔍 RAW RESPONSE: \(jsonString)")
                }
                
                if httpResponse.statusCode == 200 {
                    // Parse the nested response structure
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        print("🔍 JSON KEYS: \(json.keys)")
                        
                        if let dataDict = json["data"] as? [String: Any] {
                            print("🔍 DATA DICT KEYS: \(dataDict.keys)")
                            print("🔍 DATA DICT: \(dataDict)")
                            
                            // Try to decode with detailed error
                            if let responseData = try? JSONSerialization.data(withJSONObject: dataDict) {
                                do {
                                    let authResponse = try JSONDecoder().decode(AuthResponse.self, from: responseData)
                                    print("✅ Successfully decoded AuthResponse")
                                    self.saveAuthData(authResponse)
                                    completion(true, "Login successful")
                                } catch {
                                    print("❌ Decoding error: \(error)")
                                    if let decodingError = error as? DecodingError {
                                        switch decodingError {
                                        case .keyNotFound(let key, let context):
                                            print("❌ Key '\(key.stringValue)' not found: \(context.debugDescription)")
                                        case .typeMismatch(let type, let context):
                                            print("❌ Type mismatch for type \(type): \(context.debugDescription)")
                                        case .valueNotFound(let type, let context):
                                            print("❌ Value not found for type \(type): \(context.debugDescription)")
                                        case .dataCorrupted(let context):
                                            print("❌ Data corrupted: \(context.debugDescription)")
                                        @unknown default:
                                            print("❌ Unknown decoding error")
                                        }
                                    }
                                    completion(false, "Invalid response format: \(error.localizedDescription)")
                                }
                            } else {
                                print("❌ Failed to convert dataDict to Data")
                                completion(false, "Invalid response format")
                            }
                        } else {
                            print("❌ 'data' key not found or not a dictionary")
                            print("❌ Available keys: \(json.keys)")
                            completion(false, "Invalid response format")
                        }
                    } else {
                        print("❌ Failed to parse JSON")
                        completion(false, "Invalid response format")
                    }
                } else {
                    // Parse error message
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let errorMsg = json["error"] as? String {
                        completion(false, errorMsg)
                    } else {
                        completion(false, "Invalid credentials")
                    }
                }
            }
        }.resume()
    }
    
    // MARK: - Registration Flow
    
    func registerUser(name: String, phone: String, area: String, designation: String, organisation: String, completion: @escaping (Bool, String) -> Void) {
        guard let url = URL(string: "\(baseURL)/auth/register/request") else {
            completion(false, "Invalid URL")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: String] = [
            "name": name,
            "phone": phone,
            "area": area,
            "designation": designation,
            "organisation": organisation
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(false, error.localizedDescription)
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(false, "Invalid response")
                    return
                }
                
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if httpResponse.statusCode == 200 {
                        let message = json["message"] as? String ?? "Registration successful"
                        completion(true, message)
                    } else {
                        let errorMsg = json["error"] as? String ?? "Registration failed"
                        completion(false, errorMsg)
                    }
                } else {
                    completion(false, "Failed to register")
                }
            }
        }.resume()
    }
    
    func verifyRegistrationOTP(phone: String, otp: String, completion: @escaping (Bool, String) -> Void) {
        guard let url = URL(string: "\(baseURL)/auth/register/verify") else {
            completion(false, "Invalid URL")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-ios"
        let body = OTPVerificationRequest(phone: phone, otp: otp, deviceId: deviceId)
        request.httpBody = try? JSONEncoder().encode(body)
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(false, error.localizedDescription)
                    return
                }
                
                guard let data = data else {
                    completion(false, "No response from server")
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(false, "Invalid response")
                    return
                }
                
                if httpResponse.statusCode == 200 {
                    // Parse nested response
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let dataDict = json["data"] as? [String: Any],
                       let responseData = try? JSONSerialization.data(withJSONObject: dataDict),
                       let authResponse = try? JSONDecoder().decode(AuthResponse.self, from: responseData) {
                        self.saveAuthData(authResponse)
                        completion(true, "Registration completed successfully")
                    } else {
                        completion(false, "Invalid response format")
                    }
                } else {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let errorMsg = json["error"] as? String {
                        completion(false, errorMsg)
                    } else {
                        completion(false, "Verification failed")
                    }
                }
            }
        }.resume()
    }
    
    // MARK: - Token Management
    
    private func saveAuthData(_ response: AuthResponse) {
        UserDefaults.standard.set(response.token, forKey: "auth_token")
        UserDefaults.standard.set(response.expiresAt, forKey: "token_expiry")
        if let userData = try? JSONEncoder().encode(response.user) {
            UserDefaults.standard.set(userData, forKey: "user_data")
        }
        currentUser = response.user
        isAuthenticated = true
    }
    
    private func loadUserData() {
        if let userData = UserDefaults.standard.data(forKey: "user_data"),
           let user = try? JSONDecoder().decode(User.self, from: userData) {
            currentUser = user
        }
    }
    
    // MARK: - Logout
    
    func logout(completion: ((Bool) -> Void)? = nil) {
        guard let token = token else {
            performLogout()
            completion?(true)
            return
        }
        
        guard let url = URL(string: "\(baseURL)/auth/logout") else {
            performLogout()
            completion?(true)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { _, _, _ in
            DispatchQueue.main.async {
                self.performLogout()
                completion?(true)
            }
        }.resume()
    }
    
    private func performLogout() {
        UserDefaults.standard.removeObject(forKey: "auth_token")
        UserDefaults.standard.removeObject(forKey: "token_expiry")
        UserDefaults.standard.removeObject(forKey: "user_data")
        isAuthenticated = false
        currentUser = nil
    }
    
    // MARK: - Token Validation
    
    func validateToken(completion: @escaping (Bool) -> Void) {
        guard let token = token else {
            completion(false)
            return
        }
        
        guard let url = URL(string: "\(baseURL)/auth/validate") else {
            completion(false)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let httpResponse = response as? HTTPURLResponse,
                   httpResponse.statusCode == 200 {
                    completion(true)
                } else {
                    self.performLogout()
                    completion(false)
                }
            }
        }.resume()
    }
}
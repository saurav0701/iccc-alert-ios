import Foundation
import UIKit

class AuthManager: ObservableObject {
    static let shared = AuthManager()
    
    @Published var isAuthenticated = false
    @Published var currentUser: User?
    
    private let baseURL = "http://192.168.29.70:19998"
    
    var token: String? {
        return UserDefaults.standard.string(forKey: "auth_token")
    }
    
    private init() {
        checkAuthStatus()
    }
    
    func checkAuthStatus() {
        if let _ = UserDefaults.standard.string(forKey: "auth_token"),
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
        
        DebugLogger.shared.log("🔄 Sending OTP verification request: phone=\(phone), otp=\(otp), deviceId=\(deviceId)")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                if let error = error {
                    DebugLogger.shared.logError("Network Error: \(error.localizedDescription)")
                    print("❌ OTP Verification Network Error: \(error.localizedDescription)")
                    completion(false, error.localizedDescription)
                    return
                }
                
                guard let data = data else {
                    print("❌ No response data from OTP verification")
                    completion(false, "No response from server")
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    print("❌ Invalid HTTP response")
                    completion(false, "Invalid response")
                    return
                }
                
                // DEBUG: Print raw response
                if let jsonString = String(data: data, encoding: .utf8) {
                    print("🔍 RAW RESPONSE from server: \(jsonString)")
                }
                
                print("📊 HTTP Status Code: \(httpResponse.statusCode)")
                
                if httpResponse.statusCode == 200 {
                    // Try parsing multiple response formats
                    do {
                        print("🔄 Attempting to decode AuthResponse...")
                        
                        // First, check if response is wrapped in a "data" object
                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let dataDict = json["data"] as? [String: Any],
                           let dataJson = try? JSONSerialization.data(withJSONObject: dataDict) {
                            print("📦 Response has 'data' wrapper, extracting...")
                            let authResponse = try JSONDecoder().decode(AuthResponse.self, from: dataJson)
                            print("✅ Successfully decoded AuthResponse from wrapped response")
                            self.logAuthDetails(authResponse)
                            self.saveAuthData(authResponse)
                            print("� Auth data saved successfully")
                            completion(true, "Login successful")
                            return
                        }
                        
                        // Try parsing directly without wrapper
                        let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
                        print("✅ Successfully decoded AuthResponse directly")
                        self.logAuthDetails(authResponse)
                        self.saveAuthData(authResponse)
                        print("💾 Auth data saved successfully")
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
                        
                        // If decoding fails, still mark as authenticated if we got a 200 response
                        print("⚠️ Could not decode response, but got 200 status. Attempting fallback...")
                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            print("📋 Response JSON keys: \(json.keys.joined(separator: ", "))")
                            
                            // Try to extract token and user info from various possible locations
                            let token = (json["token"] as? String) ?? (json["access_token"] as? String) ?? ""
                            if !token.isEmpty {
                                print("✅ Found token in response, creating fallback user")
                                let fallbackUser = User(
                                    id: 0,
                                    name: "User",
                                    phone: phone,
                                    area: nil,
                                    designation: nil,
                                    organisation: nil,
                                    isActive: nil,
                                    createdAt: nil,
                                    updatedAt: nil
                                )
                                let fallbackResponse = AuthResponse(
                                    token: token,
                                    user: fallbackUser,
                                    expiresAt: Int64(Date().addingTimeInterval(24 * 60 * 60).timeIntervalSince1970)
                                )
                                self.saveAuthData(fallbackResponse)
                                print("💾 Fallback auth data saved successfully")
                                completion(true, "Login successful")
                            } else {
                                completion(false, "Invalid response format: No token found")
                            }
                        } else {
                            completion(false, "Invalid response format: \(error.localizedDescription)")
                        }
                    }
                } else {
                    // Parse error message
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let errorMsg = json["error"] as? String {
                        print("❌ Server error: \(errorMsg)")
                        completion(false, errorMsg)
                    } else {
                        print("❌ Invalid credentials or server error")
                        completion(false, "Invalid credentials")
                    }
                }
            }  // Close DispatchQueue.main.async
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
                    // Parse response directly (no wrapper)
                    do {
                        let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
                        self.saveAuthData(authResponse)
                        completion(true, "Registration completed successfully")
                    } catch {
                        print("❌ Registration verification decode error: \(error)")
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
    
    private func logAuthDetails(_ authResponse: AuthResponse) {
        print("🔐 Token received: \(authResponse.token.prefix(20))...")
        print("👤 User: \(authResponse.user.name)")
        print("📱 Phone: \(authResponse.user.phone)")
        print("🆔 User ID: \(authResponse.user.id)")
    }
    
    private func saveAuthData(_ response: AuthResponse) {
        UserDefaults.standard.set(response.token, forKey: "auth_token")
        
        // If expiresAt is provided, use it; otherwise set to 24 hours from now
        let expiresAt = response.expiresAt ?? Int64(Date().addingTimeInterval(24 * 60 * 60).timeIntervalSince1970)
        UserDefaults.standard.set(expiresAt, forKey: "token_expiry")
        
        if let userData = try? JSONEncoder().encode(response.user) {
            UserDefaults.standard.set(userData, forKey: "user_data")
        }
        currentUser = response.user
        isAuthenticated = true
        
        print("✅ Auth data saved successfully. Token expires at: \(Date(timeIntervalSince1970: TimeInterval(expiresAt)))")
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
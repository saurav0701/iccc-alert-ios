import Foundation
import UIKit

class AuthManager: ObservableObject {
    static let shared = AuthManager()
    
    @Published var isAuthenticated = false
    @Published var currentUser: User?
    
    private let baseURL = "http://103.208.173.227:8890"
    
    // ✅ FIXED: Configurable timeouts
    private let requestTimeout: TimeInterval = 30
    private let resourceTimeout: TimeInterval = 60
    
    var token: String? {
        return UserDefaults.standard.string(forKey: "auth_token")
    }
    
    private init() {
        print("🔐 AuthManager: Initializing...")
        checkAuthStatus()
    }
    
    func checkAuthStatus() {
        if let token = UserDefaults.standard.string(forKey: "auth_token"),
           let expiry = UserDefaults.standard.object(forKey: "token_expiry") as? Int64 {
            let now = Int64(Date().timeIntervalSince1970)
            isAuthenticated = expiry > now
            
            print("🔐 AuthManager: Token found, expiry=\(expiry), now=\(now), authenticated=\(isAuthenticated)")
            
            if isAuthenticated {
                loadUserData()
            }
        } else {
            print("🔐 AuthManager: No token found, not authenticated")
            isAuthenticated = false
        }
    }
    
    // ✅ FIXED: Added timeout configuration
    private func createRequest(url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
    
    func requestOTP(phone: String, completion: @escaping (Bool, String) -> Void) {
        guard let url = URL(string: "\(baseURL)/auth/login/request") else {
            completion(false, "Invalid URL")
            return
        }
        
        var request = createRequest(url: url, method: "POST")
        
        let body = LoginRequest(phone: phone, purpose: "login")
        request.httpBody = try? JSONEncoder().encode(body)
        
        print("📤 Requesting OTP for phone: \(phone)")
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                // ✅ FIXED: Better error handling
                if let error = error {
                    let errorMessage = self.handleNetworkError(error)
                    print("❌ OTP request error: \(errorMessage)")
                    completion(false, errorMessage)
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    print("❌ Invalid HTTP response")
                    completion(false, "Invalid response from server")
                    return
                }
                
                print("📥 OTP request response: \(httpResponse.statusCode)")

                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let message = json["message"] as? String {
                    if httpResponse.statusCode == 200 {
                        print("✅ OTP sent successfully")
                        completion(true, message)
                    } else {
                        let errorMsg = json["error"] as? String ?? message
                        print("❌ OTP request failed: \(errorMsg)")
                        completion(false, errorMsg)
                    }
                } else {
                    print("❌ Failed to parse OTP response")
                    completion(false, "Failed to send OTP. Please try again.")
                }
            }
        }
        
        task.resume()
    }
    
    func verifyOTP(phone: String, otp: String, completion: @escaping (Bool, String) -> Void) {
        guard let url = URL(string: "\(baseURL)/auth/login/verify") else {
            completion(false, "Invalid URL")
            return
        }
        
        var request = createRequest(url: url, method: "POST")
        
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-ios"
        let body = OTPVerificationRequest(phone: phone, otp: otp, deviceId: deviceId)
        request.httpBody = try? JSONEncoder().encode(body)
        
        print("📤 Verifying OTP for phone: \(phone)")
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                // ✅ FIXED: Better error handling
                if let error = error {
                    let errorMessage = self.handleNetworkError(error)
                    print("❌ OTP verify error: \(errorMessage)")
                    completion(false, errorMessage)
                    return
                }
                
                guard let data = data else {
                    print("❌ No data in OTP verify response")
                    completion(false, "No response from server")
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    print("❌ Invalid HTTP response")
                    completion(false, "Invalid response from server")
                    return
                }
                
                print("📥 OTP verify response: \(httpResponse.statusCode)")
                
                if let jsonString = String(data: data, encoding: .utf8) {
                    print("🔍 Response data: \(jsonString)")
                }
                
                if httpResponse.statusCode == 200 {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        print("🔍 JSON keys: \(json.keys)")
                        
                        if let dataDict = json["data"] as? [String: Any] {
                            print("🔍 Data dict keys: \(dataDict.keys)")
                            
                            if let responseData = try? JSONSerialization.data(withJSONObject: dataDict) {
                                do {
                                    let authResponse = try JSONDecoder().decode(AuthResponse.self, from: responseData)
                                    print("✅ Decoded AuthResponse successfully")
                                    print("✅ User: \(authResponse.user.name)")
                                    print("✅ Token: \(authResponse.token.prefix(10))...")
                                    
                                    self.saveAuthData(authResponse)
                                    
                                    print("✅ isAuthenticated set to: \(self.isAuthenticated)")
                                    print("✅ currentUser: \(self.currentUser?.name ?? "nil")")
                                    
                                    completion(true, "Login successful")
                                } catch {
                                    print("❌ Decoding error: \(error)")
                                    completion(false, "Invalid response format. Please try again.")
                                }
                            } else {
                                print("❌ Failed to convert dataDict to Data")
                                completion(false, "Invalid response format")
                            }
                        } else {
                            print("❌ 'data' key not found")
                            completion(false, "Invalid response format")
                        }
                    } else {
                        print("❌ Failed to parse JSON")
                        completion(false, "Invalid response format")
                    }
                } else {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let errorMsg = json["error"] as? String {
                        print("❌ Server error: \(errorMsg)")
                        completion(false, errorMsg)
                    } else {
                        print("❌ Invalid credentials")
                        completion(false, "Invalid OTP. Please try again.")
                    }
                }
            }
        }
        
        task.resume()
    }

    func registerUser(name: String, phone: String, area: String, designation: String, organisation: String, completion: @escaping (Bool, String) -> Void) {
        guard let url = URL(string: "\(baseURL)/auth/register/request") else {
            completion(false, "Invalid URL")
            return
        }
        
        var request = createRequest(url: url, method: "POST")
        
        let body: [String: String] = [
            "name": name,
            "phone": phone,
            "area": area,
            "designation": designation,
            "organisation": organisation
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        print("📤 Registering user: \(name), phone: \(phone)")
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    let errorMessage = self.handleNetworkError(error)
                    print("❌ Registration error: \(errorMessage)")
                    completion(false, errorMessage)
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(false, "Invalid response from server")
                    return
                }
                
                print("📥 Registration response: \(httpResponse.statusCode)")
                
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if httpResponse.statusCode == 200 {
                        let message = json["message"] as? String ?? "Registration successful"
                        print("✅ Registration successful")
                        completion(true, message)
                    } else {
                        let errorMsg = json["error"] as? String ?? "Registration failed"
                        print("❌ Registration failed: \(errorMsg)")
                        completion(false, errorMsg)
                    }
                } else {
                    print("❌ Failed to parse registration response")
                    completion(false, "Registration failed. Please try again.")
                }
            }
        }
        
        task.resume()
    }
    
    func verifyRegistrationOTP(phone: String, otp: String, completion: @escaping (Bool, String) -> Void) {
        guard let url = URL(string: "\(baseURL)/auth/register/verify") else {
            completion(false, "Invalid URL")
            return
        }
        
        var request = createRequest(url: url, method: "POST")
        
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-ios"
        let body = OTPVerificationRequest(phone: phone, otp: otp, deviceId: deviceId)
        request.httpBody = try? JSONEncoder().encode(body)
        
        print("📤 Verifying registration OTP for phone: \(phone)")
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    let errorMessage = self.handleNetworkError(error)
                    print("❌ Registration verify error: \(errorMessage)")
                    completion(false, errorMessage)
                    return
                }
                
                guard let data = data else {
                    completion(false, "No response from server")
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(false, "Invalid response from server")
                    return
                }
                
                print("📥 Registration verify response: \(httpResponse.statusCode)")
                
                if httpResponse.statusCode == 200 {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let dataDict = json["data"] as? [String: Any],
                       let responseData = try? JSONSerialization.data(withJSONObject: dataDict),
                       let authResponse = try? JSONDecoder().decode(AuthResponse.self, from: responseData) {
                        print("✅ Registration completed successfully")
                        self.saveAuthData(authResponse)
                        completion(true, "Registration completed successfully")
                    } else {
                        print("❌ Failed to parse registration verify response")
                        completion(false, "Invalid response format")
                    }
                } else {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let errorMsg = json["error"] as? String {
                        print("❌ Registration verify failed: \(errorMsg)")
                        completion(false, errorMsg)
                    } else {
                        completion(false, "Verification failed. Please try again.")
                    }
                }
            }
        }
        
        task.resume()
    }

    private func saveAuthData(_ response: AuthResponse) {
        print("💾 Saving auth data...")
        print("   Token: \(response.token.prefix(10))...")
        print("   Expires at: \(response.expiresAt)")
        print("   User: \(response.user.name)")
        
        UserDefaults.standard.set(response.token, forKey: "auth_token")
        UserDefaults.standard.set(response.expiresAt, forKey: "token_expiry")
        
        if let userData = try? JSONEncoder().encode(response.user) {
            UserDefaults.standard.set(userData, forKey: "user_data")
        }
        
        currentUser = response.user
        isAuthenticated = true
        
        print("✅ Auth data saved")
        print("✅ isAuthenticated = \(isAuthenticated)")
        print("✅ currentUser = \(currentUser?.name ?? "nil")")
    }
    
    private func loadUserData() {
        if let userData = UserDefaults.standard.data(forKey: "user_data"),
           let user = try? JSONDecoder().decode(User.self, from: userData) {
            currentUser = user
            print("✅ Loaded user data: \(user.name)")
        } else {
            print("⚠️ Failed to load user data")
        }
    }
    
    func logout(completion: ((Bool) -> Void)? = nil) {
        print("🚪 Logging out...")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("LOGOUT PROCESS:")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        SubscriptionManager.shared.forceSave()
        ChannelSyncState.shared.forceSave()
        print("✓ Saved current state")
        
        let subscriptions = SubscriptionManager.shared.subscribedChannels.count
        let events = SubscriptionManager.shared.getTotalEventCount()
        let saved = SubscriptionManager.shared.getSavedEvents().count
        print("✓ Current data:")
        print("  - Subscriptions: \(subscriptions)")
        print("  - Events: \(events)")
        print("  - Saved messages: \(saved)")
        
        WebSocketService.shared.disconnect()
        print("✓ WebSocket disconnected")
        
        if let token = token, let url = URL(string: "\(baseURL)/auth/logout") {
            var request = createRequest(url: url, method: "POST")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            
            URLSession.shared.dataTask(with: request) { _, _, _ in
                DispatchQueue.main.async {
                    self.performLogout()
                    completion?(true)
                }
            }.resume()
        } else {
            performLogout()
            completion?(true)
        }
    }

    private func performLogout() {
        isAuthenticated = false
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("✅ LOGOUT COMPLETE")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("DATA PRESERVATION:")
        print("  ✓ Token preserved: \(token != nil)")
        print("  ✓ User data: \(currentUser?.name ?? "nil")")
        print("  ✓ Subscriptions: \(SubscriptionManager.shared.subscribedChannels.count)")
        print("  ✓ Events: \(SubscriptionManager.shared.getTotalEventCount())")
        print("  ✓ Saved messages: \(SubscriptionManager.shared.getSavedEvents().count)")
        print("")
        print("WHAT HAPPENS NEXT:")
        print("  → User will see login screen")
        print("  → WebSocket is disconnected")
        print("  → All data is preserved")
        print("  → On re-login with same phone:")
        print("    • Same clientId will be used")
        print("    • Backend will send all pending events")
        print("    • Events will be ACKed as processed")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    }

    func validateToken(completion: @escaping (Bool) -> Void) {
        guard let token = token else {
            completion(false)
            return
        }
        
        guard let url = URL(string: "\(baseURL)/auth/validate") else {
            completion(false)
            return
        }
        
        var request = createRequest(url: url, method: "GET")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let httpResponse = response as? HTTPURLResponse,
                   httpResponse.statusCode == 200 {
                    completion(true)
                } else {
                    self.performFullLogout()
                    completion(false)
                }
            }
        }.resume()
    }

    private func performFullLogout() {
        UserDefaults.standard.removeObject(forKey: "auth_token")
        UserDefaults.standard.removeObject(forKey: "token_expiry")
        UserDefaults.standard.removeObject(forKey: "user_data")
        isAuthenticated = false
        currentUser = nil
        print("✅ Full logout - token expired, all data cleared")
    }
    
    // ✅ NEW: User-friendly error messages
    private func handleNetworkError(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "No internet connection. Please check your network and try again."
            case .timedOut:
                return "Request timed out. Please check your connection and try again."
            case .cannotFindHost, .cannotConnectToHost:
                return "Cannot reach server. Please try again later."
            case .networkConnectionLost:
                return "Network connection lost. Please try again."
            default:
                return "Network error. Please check your connection and try again."
            }
        }
        return "An error occurred. Please try again."
    }
}
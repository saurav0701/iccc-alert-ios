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
        
        print("📤 Requesting OTP for phone: \(phone)")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("❌ OTP request error: \(error.localizedDescription)")
                    completion(false, error.localizedDescription)
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    print("❌ Invalid HTTP response")
                    completion(false, "Invalid response")
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
        
        print("📤 Verifying OTP for phone: \(phone)")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("❌ OTP verify error: \(error.localizedDescription)")
                    completion(false, error.localizedDescription)
                    return
                }
                
                guard let data = data else {
                    print("❌ No data in OTP verify response")
                    completion(false, "No response from server")
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    print("❌ Invalid HTTP response")
                    completion(false, "Invalid response")
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
                                    completion(false, "Invalid response format: \(error.localizedDescription)")
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
                        completion(false, "Invalid credentials")
                    }
                }
            }
        }.resume()
    }

    
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
        
        print("📤 Registering user: \(name), phone: \(phone)")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("❌ Registration error: \(error.localizedDescription)")
                    completion(false, error.localizedDescription)
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(false, "Invalid response")
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
        
        print("📤 Verifying registration OTP for phone: \(phone)")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("❌ Registration verify error: \(error.localizedDescription)")
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
                        completion(false, "Verification failed")
                    }
                }
            }
        }.resume()
    }
    
    // MARK: - Token Management
    
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
        print("✅ Logged out successfully")
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
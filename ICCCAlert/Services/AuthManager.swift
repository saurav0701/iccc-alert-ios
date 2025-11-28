import Foundation
import UIKit

class AuthManager: ObservableObject {
    static let shared = AuthManager()
    
    @Published var isAuthenticated = false
    @Published var currentUser: User?
    
    private let baseURL = "https://iccc-backend.onrender.com"
    
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
                
                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 200 {
                        completion(true, "OTP sent to WhatsApp")
                    } else {
                        completion(false, "Failed to send OTP")
                    }
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
                guard let data = data else {
                    completion(false, "No response")
                    return
                }
                
                if let authResponse = try? JSONDecoder().decode(AuthResponse.self, from: data) {
                    self.saveAuthData(authResponse)
                    completion(true, "Login successful")
                } else {
                    completion(false, "Invalid credentials")
                }
            }
        }.resume()
    }
    
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
    
    func logout() {
        UserDefaults.standard.removeObject(forKey: "auth_token")
        UserDefaults.standard.removeObject(forKey: "token_expiry")
        UserDefaults.standard.removeObject(forKey: "user_data")
        isAuthenticated = false
        currentUser = nil
    }
}
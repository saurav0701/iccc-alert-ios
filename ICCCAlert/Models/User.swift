import Foundation

// MARK: - User Model (matches backend)
struct User: Codable {
    let id: Int
    let name: String
    let phone: String
    let area: String
    let designation: String
    let organisation: String  // Changed from workingFor
    let isActive: Bool
    let createdAt: String
    let updatedAt: String
}

// MARK: - Auth Response (matches backend nested structure)
struct AuthResponse: Codable {
    let token: String
    let expiresAt: Int64
    let user: User
}

// MARK: - Login Request
struct LoginRequest: Codable {
    let phone: String
    let purpose: String
}

// MARK: - OTP Verification Request
struct OTPVerificationRequest: Codable {
    let phone: String
    let otp: String
    let deviceId: String
}

// MARK: - Registration Request
struct RegistrationRequest: Codable {
    let name: String
    let phone: String
    let area: String
    let designation: String
    let organisation: String  // CCL or BCCL
}
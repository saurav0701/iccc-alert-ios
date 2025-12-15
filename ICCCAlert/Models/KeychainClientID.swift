import Foundation
import Security
import UIKit

/// Manages persistent client ID stored in iOS Keychain
/// This survives app reinstalls, similar to Android's ANDROID_ID behavior
class KeychainClientID {
    
    static let service = "com.iccc.alert.clientid"
    private static let account = "websocket_client_id"
    
    /// Get or create a persistent client ID
    /// - Returns: Stable client ID that survives app reinstalls
    static func getOrCreateClientID() -> String {
        // Try to retrieve existing client ID from Keychain
        if let existingID = retrieveFromKeychain() {
            print("✅ Using existing Keychain client ID: \(existingID)")
            return existingID
        }
        
        // Generate new client ID
        let newID = generateClientID()
        
        // Save to Keychain
        if saveToKeychain(clientID: newID) {
            print("✅ Created and saved new client ID: \(newID)")
        } else {
            print("⚠️ Failed to save client ID to Keychain, using temporary ID")
        }
        
        return newID
    }
    
    /// Retrieve client ID from Keychain
    static func retrieveFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        
        guard status == errSecSuccess,
              let data = dataTypeRef as? Data,
              let clientID = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return clientID
    }
    
    /// Save client ID to Keychain
    private static func saveToKeychain(clientID: String) -> Bool {
        guard let data = clientID.data(using: .utf8) else {
            return false
        }
        
        // First try to delete existing item (in case of update)
        deleteFromKeychain()
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock // Available after device unlock
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    /// Delete client ID from Keychain (for testing or reset)
    static func deleteFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        
        SecItemDelete(query as CFDictionary)
    }
    
    /// Generate a new client ID similar to Android implementation
    private static func generateClientID() -> String {
        // Use iOS Vendor ID as base (similar to Android ID)
        let vendorID = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        
        // Add short UUID for additional uniqueness
        let uuid = UUID().uuidString.prefix(8)
        
        // Format: ios-<vendor-id>-<short-uuid>
        return "ios-\(vendorID)-\(uuid)"
    }
    
    /// Reset client ID (for debugging or user-initiated reset)
    /// WARNING: This will orphan existing durable consumers on server
    static func resetClientID() -> String {
        print("⚠️ Resetting client ID - this will orphan old durable consumers")
        deleteFromKeychain()
        return getOrCreateClientID()
    }
    
    /// Check if client ID exists in Keychain
    static func hasClientID() -> Bool {
        return retrieveFromKeychain() != nil
    }
}

// MARK: - Alternative: Server-Generated Client ID

/// Alternative approach: Let server generate and manage client IDs
/// This is the most robust solution for cross-platform consistency
class ServerManagedClientID {
    
    private static let keychainKey = "server_assigned_client_id"
    
    /// Get client ID - either from Keychain or request from server
    static func getOrRequestClientID(phoneNumber: String, completion: @escaping (String?) -> Void) {
        // Check Keychain first
        if let existingID = KeychainClientID.retrieveFromKeychain() {
            print("✅ Using existing server-assigned client ID: \(existingID)")
            completion(existingID)
            return
        }
        
        // Request new client ID from server
        requestClientIDFromServer(phoneNumber: phoneNumber) { serverID in
            if let serverID = serverID {
                // Save to Keychain
                _ = saveServerClientID(clientID: serverID)
                completion(serverID)
            } else {
                // Fallback to local generation
                let fallbackID = KeychainClientID.getOrCreateClientID()
                completion(fallbackID)
            }
        }
    }
    
    /// Request client ID from backend
    private static func requestClientIDFromServer(phoneNumber: String, completion: @escaping (String?) -> Void) {
        
        
        guard let url = URL(string: "http://192.168.29.70:19998/api/client-id") else {
            completion(nil)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "phone": phoneNumber,
            "platform": "ios",
            "deviceInfo": [
                "model": UIDevice.current.model,
                "systemVersion": UIDevice.current.systemVersion,
                "vendorId": UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
            ]
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let clientId = json["clientId"] as? String else {
                completion(nil)
                return
            }
            
            DispatchQueue.main.async {
                completion(clientId)
            }
        }.resume()
    }
    
    private static func saveServerClientID(clientID: String) -> Bool {
        guard let data = clientID.data(using: .utf8) else {
            return false
        }
        
        KeychainClientID.deleteFromKeychain()
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainClientID.service,
            kSecAttrAccount as String: keychainKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }
}
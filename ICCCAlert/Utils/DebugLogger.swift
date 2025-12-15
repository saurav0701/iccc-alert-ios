import Foundation

/// Debug logger that writes to UserDefaults for inspection on Windows development
class DebugLogger {
    static let shared = DebugLogger()
    
    private let userDefaults = UserDefaults.standard
    private let logKey = "debug_logs"
    private let maxLogs = 100
    
    private init() {}
    
    func log(_ message: String, level: String = "INFO") {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logEntry = "[\(timestamp)] [\(level)] \(message)"
        
        // Print to console (visible in Xcode if testing there)
        print(logEntry)
        
        // Also save to UserDefaults
        var logs = userDefaults.stringArray(forKey: logKey) ?? []
        logs.append(logEntry)
        
        // Keep only last N logs to avoid excessive storage
        if logs.count > maxLogs {
            logs = Array(logs.suffix(maxLogs))
        }
        
        userDefaults.set(logs, forKey: logKey)
    }
    
    func logError(_ message: String) {
        log(message, level: "ERROR")
    }
    
    func logSuccess(_ message: String) {
        log(message, level: "SUCCESS")
    }
    
    func logWarning(_ message: String) {
        log(message, level: "WARNING")
    }
    
    func getLogs() -> [String] {
        return userDefaults.stringArray(forKey: logKey) ?? []
    }
    
    func clearLogs() {
        userDefaults.removeObject(forKey: logKey)
    }
    
    func getLogsAsString() -> String {
        return getLogs().joined(separator: "\n")
    }
}

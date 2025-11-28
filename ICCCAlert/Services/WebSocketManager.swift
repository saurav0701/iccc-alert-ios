import Foundation
import UIKit  // ← ADD THIS LINE

class WebSocketManager: ObservableObject {
    @Published var isConnected = false
    @Published var connectionError: String?
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private let authManager: AuthManager
    
    init(authManager: AuthManager) {
        self.authManager = authManager
    }
    
    func connect() {
        disconnect()
        
        guard let token = authManager.token else {
            connectionError = "No authentication token available"
            return
        }
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config)
        
        var components = URLComponents(string: "wss://iccc-backend.onrender.com/ws")
        let clientId = UIDevice.current.identifierForVendor?.uuidString ?? "ios-client"
        components?.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "client_id", value: clientId)
        ]
        
        guard let url = components?.url else {
            connectionError = "Invalid WebSocket URL"
            return
        }
        
        webSocketTask = session?.webSocketTask(with: url)
        webSocketTask?.resume()
        
        isConnected = true
        connectionError = nil
        
        receiveMessage()
    }
    
    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
    }
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                self?.handleMessage(message)
                self?.receiveMessage()
            case .failure(let error):
                DispatchQueue.main.async {
                    self?.connectionError = error.localizedDescription
                    self?.isConnected = false
                }
            }
        }
    }
    
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            print("WebSocket received: \(text)")
        case .data(let data):
            print("WebSocket received data: \(data)")
        @unknown default:
            break
        }
    }
}
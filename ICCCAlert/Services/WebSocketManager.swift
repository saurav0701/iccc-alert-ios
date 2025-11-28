import Foundation
import Starscream

class WebSocketManager: ObservableObject {
    static let shared = WebSocketManager()
    
    private var socket: WebSocket?
    private let wsURL = "ws://202.140.131.90:2222/ws"
    
    @Published var isConnected = false
    @Published var events: [Event] = []
    
    private init() {
        connect()
    }
    
    func connect() {
        guard let url = URL(string: wsURL) else {
            print("❌ Invalid WebSocket URL")
            return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        
        socket = WebSocket(request: request)
        socket?.delegate = self
        socket?.connect()
        
        print("📡 Connecting to WebSocket...")
    }
    
    func disconnect() {
        socket?.disconnect()
        isConnected = false
        print("📡 Disconnected from WebSocket")
    }
}

extension WebSocketManager: WebSocketDelegate {
    func didReceive(event: WebSocketEvent, client: WebSocketClient) {
        switch event {
        case .connected(let headers):
            isConnected = true
            print("✅ WebSocket connected")
            print("Headers: \(headers)")
            
        case .disconnected(let reason, let code):
            isConnected = false
            print("❌ WebSocket disconnected: \(reason) with code: \(code)")
            
        case .text(let string):
            print("📩 Received: \(string)")
            handleMessage(string)
            
        case .binary(let data):
            print("📩 Received binary data: \(data.count) bytes")
            
        case .error(let error):
            print("❌ WebSocket error: \(error?.localizedDescription ?? "unknown")")
            
        case .cancelled:
            isConnected = false
            print("⚠️ WebSocket cancelled")
            
        default:
            break
        }
    }
    
    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        
        do {
            let decoder = JSONDecoder()
            let event = try decoder.decode(Event.self, from: data)
            
            DispatchQueue.main.async {
                self.events.insert(event, at: 0)
                
                // Keep only last 100 events
                if self.events.count > 100 {
                    self.events.removeLast()
                }
            }
            
            print("✅ Decoded event: \(event.typeDisplay ?? "unknown")")
        } catch {
            print("❌ Failed to decode event: \(error)")
        }
    }
}
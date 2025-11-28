import Foundation

class WebSocketManager: ObservableObject {
    static let shared = WebSocketManager()
    
    @Published var events: [Event] = []
    @Published var isConnected = false
    
    private var webSocketTask: URLSessionWebSocketTask?
    private let wsURL = URL(string: "ws://202.140.131.90:2222/ws")!
    
    private init() {}
    
    func connect() {
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: wsURL)
        webSocketTask?.resume()
        isConnected = true
        receiveMessage()
        
        print("✅ WebSocket connected")
    }
    
    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        isConnected = false
        print("❌ WebSocket disconnected")
    }
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self?.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self?.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                self?.receiveMessage()
                
            case .failure(let error):
                print("WebSocket error: \(error)")
                self?.isConnected = false
                // Reconnect after 5 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    self?.connect()
                }
            }
        }
    }
    
    private func handleMessage(_ text: String) {
        print("📨 Received: \(text.prefix(100))...")
        
        if let data = text.data(using: .utf8),
           let event = try? JSONDecoder().decode(Event.self, from: data) {
            DispatchQueue.main.async {
                self.events.insert(event, at: 0)
                if self.events.count > 100 {
                    self.events.removeLast()
                }
                print("✅ Event added: \(event.typeDisplay ?? "Unknown")")
            }
        }
    }
    
    func sendSubscription(channels: [Channel]) {
        let filters = channels.map { SubscriptionFilter(area: $0.area, eventType: $0.eventType) }
        let clientId = UIDevice.current.identifierForVendor?.uuidString ?? "ios-client"
        let request = SubscriptionRequest(clientId: clientId, filters: filters)
        
        if let jsonData = try? JSONEncoder().encode(request),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            let message = URLSessionWebSocketTask.Message.string(jsonString)
            webSocketTask?.send(message) { error in
                if let error = error {
                    print("❌ Send error: \(error)")
                } else {
                    print("✅ Subscription sent: \(channels.count) channels")
                }
            }
        }
    }
}
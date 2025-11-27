import Foundation

class WebSocketManager: ObservableObject {
    static let shared = WebSocketManager()
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var eventListeners: [(Event) -> Void] = []
    
    private let wsURL = URL(string: "ws://202.140.131.90:2222/ws")!
    
    func connect() {
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: wsURL)
        webSocketTask?.resume()
        
        receiveMessage()
        print("✅ WebSocket connecting...")
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
                print("❌ WebSocket error: \(error)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    self?.connect()
                }
            }
        }
    }
    
    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let event = try? JSONDecoder().decode(Event.self, from: data) else {
            return
        }
        
        // Notify all listeners
        eventListeners.forEach { $0(event) }
    }
    
    func addListener(_ listener: @escaping (Event) -> Void) {
        eventListeners.append(listener)
    }
    
    func removeAllListeners() {
        eventListeners.removeAll()
    }
}
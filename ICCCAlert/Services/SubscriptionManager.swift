import Foundation

class SubscriptionManager: ObservableObject {
    @Published var subscribedChannels: [Channel] = []
    
    private let baseURL = "https://iccc-backend.onrender.com"
    private let authManager: AuthManager
    
    init(authManager: AuthManager) {
        self.authManager = authManager
        loadSubscriptions()
    }
    
    func checkSubscription(channelId: String, completion: @escaping (Result<Bool, Error>) -> Void) {
        let isSubscribed = subscribedChannels.contains(where: { $0.id == channelId })
        completion(.success(isSubscribed))
    }
    
    func subscribe(to channelId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let token = authManager.token else {
            completion(.failure(NSError(domain: "SubscriptionManager", code: 401, userInfo: [NSLocalizedDescriptionKey: "Not authenticated"])))
            return
        }
        
        guard let url = URL(string: "\(baseURL)/api/subscriptions") else {
            completion(.failure(NSError(domain: "SubscriptionManager", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = ["channelId": channelId]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error))
                    return
                }
                
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    self?.loadSubscriptions()
                    completion(.success(()))
                } else {
                    completion(.failure(NSError(domain: "SubscriptionManager", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to subscribe"])))
                }
            }
        }.resume()
    }
    
    func unsubscribe(from channelId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let token = authManager.token else {
            completion(.failure(NSError(domain: "SubscriptionManager", code: 401, userInfo: [NSLocalizedDescriptionKey: "Not authenticated"])))
            return
        }
        
        guard let url = URL(string: "\(baseURL)/api/subscriptions/\(channelId)") else {
            completion(.failure(NSError(domain: "SubscriptionManager", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error))
                    return
                }
                
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    self?.subscribedChannels.removeAll { $0.id == channelId }
                    self?.saveSubscriptions()
                    completion(.success(()))
                } else {
                    completion(.failure(NSError(domain: "SubscriptionManager", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to unsubscribe"])))
                }
            }
        }.resume()
    }
    
    private func saveSubscriptions() {
        if let data = try? JSONEncoder().encode(subscribedChannels) {
            UserDefaults.standard.set(data, forKey: "subscribed_channels")
        }
    }
    
    private func loadSubscriptions() {
        if let data = UserDefaults.standard.data(forKey: "subscribed_channels"),
           let channels = try? JSONDecoder().decode([Channel].self, from: data) {
            subscribedChannels = channels
        }
    }
}
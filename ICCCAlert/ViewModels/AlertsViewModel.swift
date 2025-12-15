import Foundation
import Combine

class AlertsViewModel: ObservableObject {
    @Published var alerts: [Event] = []
    @Published var isLoading = false
    @Published var error: String?
    
    private let authManager: AuthManager
    private let baseURL = "https://iccc-backend.onrender.com"
    private var cancellables = Set<AnyCancellable>()
    
    init(authManager: AuthManager) {
        self.authManager = authManager
    }
    
    func fetchAlerts() {
        guard let token = authManager.token else {
            error = "Not authenticated"
            return
        }
        
        isLoading = true
        error = nil
        
        guard let url = URL(string: "\(baseURL)/api/events") else {
            error = "Invalid URL"
            isLoading = false
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTaskPublisher(for: request)
            .map(\.data)
            .decode(type: [Event].self, decoder: JSONDecoder())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] completion in
                self?.isLoading = false
                if case .failure(let error) = completion {
                    self?.error = error.localizedDescription
                }
            } receiveValue: { [weak self] events in
                self?.alerts = events
            }
            .store(in: &cancellables)
    }
    
    func markAsRead(_ alert: Event) {
        guard let token = authManager.token else { return }
        guard let alertId = alert.id else { return }
        
        guard let url = URL(string: "\(baseURL)/api/events/\(alertId)/read") else {
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { [weak self] _, _, _ in
            DispatchQueue.main.async {
                if let index = self?.alerts.firstIndex(where: { $0.id == alert.id }) {
                    let updatedAlert = self?.alerts[index]
                    // Note: You'll need to add isRead property to Event model
                    if let _ = updatedAlert {
                        // Event marked as read on server
                    }
                }
            }
        }.resume()
    }
    
    func markAllAsRead() {
        guard let token = authManager.token else { return }
        
        guard let url = URL(string: "\(baseURL)/api/events/read-all") else {
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { [weak self] _, _, _ in
            DispatchQueue.main.async {
                self?.fetchAlerts()
            }
        }.resume()
    }
}
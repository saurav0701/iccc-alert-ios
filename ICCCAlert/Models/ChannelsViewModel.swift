import Foundation
import Combine

class ChannelsViewModel: ObservableObject {
    @Published var channels: [Channel] = []
    @Published var categories: [String] = []
    @Published var isLoading = false
    @Published var error: String?
    
    let authManager: AuthManager
    private var cancellables = Set<AnyCancellable>()
    
    init(authManager: AuthManager) {
        self.authManager = authManager
    }
    
    func fetchChannels() {
        guard let token = authManager.token else {
            error = "Not authenticated"
            return
        }
        
        isLoading = true
        error = nil
        
        var request = URLRequest(url: URL(string: "https://iccc-backend.onrender.com/api/channels")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTaskPublisher(for: request)
            .map(\.data)
            .decode(type: [Channel].self, decoder: JSONDecoder())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] completion in
                self?.isLoading = false
                if case .failure(let error) = completion {
                    self?.error = error.localizedDescription
                }
            } receiveValue: { [weak self] channels in
                self?.channels = channels
                self?.categories = Array(Set(channels.map { $0.category })).sorted()
            }
            .store(in: &cancellables)
    }
}
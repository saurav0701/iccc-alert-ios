import Foundation
import Combine

class AlertsViewModel: ObservableObject {
    @Published var events: [Event] = []
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        WebSocketManager.shared.$events
            .receive(on: DispatchQueue.main)
            .assign(to: &$events)
    }
}
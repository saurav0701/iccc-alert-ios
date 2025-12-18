import Foundation
import Combine

class ChannelsViewModel: ObservableObject {
    @Published var channels: [Channel] = []
    @Published var filteredChannels: [Channel] = []
    @Published var categories: [String] = []
    @Published var selectedCategory: String?
    @Published var searchText = ""
    
    private var cancellables = Set<AnyCancellable>()
    private let subscriptionManager = SubscriptionManager.shared
    
    init() {
        loadChannels()
        setupObservers()
    }
    
    private func loadChannels() {
        // Get all available channels
        var allChannels = SubscriptionManager.getAllAvailableChannels()
        
        // Mark which ones are subscribed
        let subscribedIds = Set(subscriptionManager.subscribedChannels.map { $0.id })
        
        allChannels = allChannels.map { channel in
            var updated = channel
            updated.isSubscribed = subscribedIds.contains(channel.id)
            return updated
        }
        
        self.channels = allChannels
        
        // ✅ FIXED: Extract categories from eventTypeDisplay instead of category
        self.categories = Array(Set(allChannels.map { $0.eventTypeDisplay })).sorted()
        
        applyFilters()
    }
    
    private func setupObservers() {
        // Observe search text changes
        $searchText
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyFilters()
            }
            .store(in: &cancellables)
        
        // Observe category changes
        $selectedCategory
            .sink { [weak self] _ in
                self?.applyFilters()
            }
            .store(in: &cancellables)
        
        // Observe subscription changes
        NotificationCenter.default.publisher(for: NSNotification.Name("SubscriptionChanged"))
            .sink { [weak self] _ in
                self?.loadChannels()
            }
            .store(in: &cancellables)
    }
    
    private func applyFilters() {
        var result = channels
        
        // Apply category filter
        if let category = selectedCategory {
            result = result.filter { $0.eventTypeDisplay == category }
        }
        
        // Apply search filter
        if !searchText.isEmpty {
            result = result.filter {
                $0.areaDisplay.localizedCaseInsensitiveContains(searchText) ||
                $0.eventTypeDisplay.localizedCaseInsensitiveContains(searchText)
            }
        }
        
        filteredChannels = result
    }
    
    func subscribe(to channel: Channel) {
        subscriptionManager.subscribe(channel: channel)
        loadChannels()
    }
    
    func unsubscribe(from channelId: String) {
        subscriptionManager.unsubscribe(channelId: channelId)
        loadChannels()
    }
    
    func refresh() {
        loadChannels()
    }
}
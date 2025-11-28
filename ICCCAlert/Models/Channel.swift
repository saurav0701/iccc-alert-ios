import Foundation

struct Channel: Identifiable, Codable, Equatable {
    let id: String
    let area: String
    let areaDisplay: String
    let eventType: String
    let eventTypeDisplay: String
    let description: String
    var isSubscribed: Bool = false
    var isMuted: Bool = false
    var isPinned: Bool = false
    
    static func == (lhs: Channel, rhs: Channel) -> Bool {
        return lhs.id == rhs.id
    }
}

struct SubscriptionFilter: Codable {
    let area: String
    let eventType: String
}

struct SubscriptionRequest: Codable {
    let clientId: String
    let filters: [SubscriptionFilter]
}
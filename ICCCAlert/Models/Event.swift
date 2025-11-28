import Foundation

struct Event: Identifiable, Codable {
    // Use eventId as the actual id, but provide UUID fallback
    var id: String { eventId ?? UUID().uuidString }
    
    let eventId: String?
    let timestamp: Int64
    let source: String?
    let area: String?
    let areaDisplay: String?
    let type: String?
    let typeDisplay: String?
    let data: [String: String]
    
    private enum CodingKeys: String, CodingKey {
        case eventId = "id"
        case timestamp, source, area, areaDisplay, type, typeDisplay, data
    }
    
    // Initializer for creating test events
    init(eventId: String? = nil, timestamp: Int64 = 0, source: String? = nil,
         area: String? = nil, areaDisplay: String? = nil, type: String? = nil,
         typeDisplay: String? = nil, data: [String: String] = [:]) {
        self.eventId = eventId
        self.timestamp = timestamp
        self.source = source
        self.area = area
        self.areaDisplay = areaDisplay
        self.type = type
        self.typeDisplay = typeDisplay
        self.data = data
    }
}
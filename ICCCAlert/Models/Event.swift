import Foundation

struct Event: Identifiable, Codable {
    let id: String
    let timestamp: Int64
    let area: String
    let areaDisplay: String
    let type: String
    let typeDisplay: String
    let location: String
    
    init(id: String = UUID().uuidString, 
         timestamp: Int64 = Int64(Date().timeIntervalSince1970),
         area: String, 
         areaDisplay: String,
         type: String,
         typeDisplay: String,
         location: String) {
        self.id = id
        self.timestamp = timestamp
        self.area = area
        self.areaDisplay = areaDisplay
        self.type = type
        self.typeDisplay = typeDisplay
        self.location = location
    }
}
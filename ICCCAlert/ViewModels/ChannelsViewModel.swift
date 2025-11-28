import Foundation

class ChannelsViewModel: ObservableObject {
    @Published var allChannels: [Channel] = []
    
    init() {
        loadChannels()
    }
    
    func loadChannels() {
        let areas = [
            ("sijua", "Sijua"),
            ("kusunda", "Kusunda"),
            ("bastacolla", "Bastacolla"),
            ("lodna", "Lodna"),
            ("govindpur", "Govindpur"),
            ("barora", "Barora"),
            ("ccwo", "CCWO"),
            ("ej", "EJ"),
            ("cvarea", "CV Area"),
            ("wjarea", "WJ Area"),
            ("pbarea", "PB Area"),
            ("block2", "Block 2"),
            ("katras", "Katras")
        ]
        
        let eventTypes = [
            ("cd", "Crowd Detection"),
            ("vd", "Vehicle Detection"),
            ("pd", "Person Detection"),
            ("id", "Intrusion Detection"),
            ("vc", "Vehicle Congestion"),
            ("ls", "Loading Status"),
            ("us", "Unloading Status"),
            ("ct", "Camera Tampering"),
            ("sh", "Safety Hazard"),
            ("ii", "Insufficient Illumination"),
            ("off-route", "Off-Route Alert"),
            ("tamper", "Tamper Alert")
        ]
        
        allChannels = areas.flatMap { area in
            eventTypes.map { eventType in
                Channel(
                    id: "\(area.0)_\(eventType.0)",
                    area: area.0,
                    areaDisplay: area.1,
                    eventType: eventType.0,
                    eventTypeDisplay: eventType.1,
                    description: "\(area.1) - \(eventType.1)"
                )
            }
        }
    }
}
import SwiftUI

// MARK: - Filter Enums

enum SystemFilter: String, CaseIterable {
    case all = "All"
    case va = "VA"
    case vts = "VTS"
}

enum TimeFilter: Equatable {
    case all
    case today
    case yesterday
    case custom(startDate: Date, endDate: Date)
    
    var displayText: String {
        switch self {
        case .all: return "All Time"
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .custom: return "Custom"
        }
    }
    
    static func == (lhs: TimeFilter, rhs: TimeFilter) -> Bool {
        switch (lhs, rhs) {
        case (.all, .all), (.today, .today), (.yesterday, .yesterday):
            return true
        case (.custom(let start1, let end1), .custom(let start2, let end2)):
            return start1 == start2 && end1 == end2
        default:
            return false
        }
    }
}

// MARK: - Filter State

class FilterState: ObservableObject {
    @Published var systemFilter: SystemFilter = .all
    @Published var timeFilter: TimeFilter = .all
    @Published var selectedAreas: Set<String> = []
    @Published var selectedEventTypes: Set<String> = []
    @Published var showOnlySaved: Bool = false
    
    var activeFilterCount: Int {
        var count = 0
        if systemFilter != .all { count += 1 }
        if timeFilter != .all { count += 1 }
        if showOnlySaved { count += 1 }
        if !selectedAreas.isEmpty { count += 1 }
        if !selectedEventTypes.isEmpty { count += 1 }
        return count
    }
    
    func clearAll() {
        systemFilter = .all
        timeFilter = .all
        selectedAreas.removeAll()
        selectedEventTypes.removeAll()
        showOnlySaved = false
    }
    
    func matchesEvent(_ event: Event, channel: Channel, vtsEventTypes: [String]) -> Bool {
        // System filter
        let isVtsChannel = vtsEventTypes.contains(channel.eventType)
        switch systemFilter {
        case .va:
            if isVtsChannel { return false }
        case .vts:
            if !isVtsChannel { return false }
        case .all:
            break
        }
        
        // Time filter
        if !matchesTimeFilter(event.date) {
            return false
        }
        
        // Area filter
        if !selectedAreas.isEmpty, !selectedAreas.contains(channel.area) {
            return false
        }
        
        // Event type filter
        if !selectedEventTypes.isEmpty, !selectedEventTypes.contains(channel.eventTypeDisplay) {
            return false
        }
        
        // Saved filter
        if showOnlySaved && !event.isSaved {
            return false
        }
        
        return true
    }
    
    private func matchesTimeFilter(_ date: Date) -> Bool {
        let calendar = Calendar.current
        
        switch timeFilter {
        case .all:
            return true
            
        case .today:
            return calendar.isDateInToday(date)
            
        case .yesterday:
            return calendar.isDateInYesterday(date)
            
        case .custom(let startDate, let endDate):
            return date >= startDate && date <= endDate
        }
    }
}

// MARK: - Filter Chip View

struct FilterChip: View {
    let title: String
    let icon: String
    let color: Color
    let onRemove: () -> Void
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
            
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
            
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color)
        .cornerRadius(8)
    }
}

// MARK: - Multiple Selection Row

struct MultipleSelectionRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundColor(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.blue)
                }
            }
        }
    }
}
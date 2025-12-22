import SwiftUI

// MARK: - Time Filter Types

enum TimeFilter: Equatable, Codable {
    case all
    case today
    case yesterday
    case custom(startDate: Date, endDate: Date)
    
    enum CodingKeys: String, CodingKey {
        case type, startDate, endDate
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        
        switch type {
        case "all": self = .all
        case "today": self = .today
        case "yesterday": self = .yesterday
        case "custom":
            let start = try container.decode(Date.self, forKey: .startDate)
            let end = try container.decode(Date.self, forKey: .endDate)
            self = .custom(startDate: start, endDate: end)
        default: self = .all
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .all:
            try container.encode("all", forKey: .type)
        case .today:
            try container.encode("today", forKey: .type)
        case .yesterday:
            try container.encode("yesterday", forKey: .type)
        case .custom(let start, let end):
            try container.encode("custom", forKey: .type)
            try container.encode(start, forKey: .startDate)
            try container.encode(end, forKey: .endDate)
        }
    }
    
    var displayName: String {
        switch self {
        case .all: return "All Time"
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .custom: return "Custom Range"
        }
    }
    
    func matches(eventDate: Date) -> Bool {
        let calendar = Calendar.current
        let now = Date()
        
        switch self {
        case .all:
            return true
            
        case .today:
            return calendar.isDateInToday(eventDate)
            
        case .yesterday:
            return calendar.isDateInYesterday(eventDate)
            
        case .custom(let startDate, let endDate):
            return eventDate >= startDate && eventDate <= endDate
        }
    }
}

// MARK: - Sort Options

enum EventSortOption {
    case newestFirst
    case oldestFirst
    
    var displayName: String {
        switch self {
        case .newestFirst: return "Newest First"
        case .oldestFirst: return "Oldest First"
        }
    }
}

// MARK: - Channel Detail Filter Sheet

struct ChannelDetailFilterSheet: View {
    @Environment(\.presentationMode) var presentationMode
    
    @Binding var timeFilter: TimeFilter
    @Binding var sortOption: EventSortOption
    @Binding var showOnlySaved: Bool
    
    @State private var showCustomDatePicker = false
    @State private var customStartDate = Date()
    @State private var customEndDate = Date()
    
    let totalEventCount: Int
    let savedEventCount: Int
    
    var body: some View {
        NavigationView {
            List {
                // Stats Section
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Total Events")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(totalEventCount)")
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.blue)
                        }
                        
                        Spacer()
                        
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("Saved")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(savedEventCount)")
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.yellow)
                        }
                    }
                    .padding(.vertical, 8)
                }
                
                // Time Filter Section
                Section(header: Text("Time Period").font(.headline)) {
                    TimeFilterButton(
                        title: "All Time",
                        icon: "calendar",
                        isSelected: timeFilter == .all
                    ) {
                        timeFilter = .all
                    }
                    
                    TimeFilterButton(
                        title: "Today",
                        icon: "calendar.circle.fill",
                        isSelected: timeFilter == .today
                    ) {
                        timeFilter = .today
                    }
                    
                    TimeFilterButton(
                        title: "Yesterday",
                        icon: "calendar.badge.clock",
                        isSelected: timeFilter == .yesterday
                    ) {
                        timeFilter = .yesterday
                    }
                    
                    Button(action: { showCustomDatePicker = true }) {
                        HStack {
                            Image(systemName: "calendar.badge.plus")
                                .foregroundColor(.purple)
                            
                            if case .custom(let start, let end) = timeFilter {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Custom Range")
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                    Text("\(formatDate(start)) - \(formatDate(end))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            } else {
                                Text("Custom Range")
                                    .foregroundColor(.primary)
                            }
                            
                            Spacer()
                            
                            if case .custom = timeFilter {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.blue)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                
                // Sort Section
                Section(header: Text("Sort By").font(.headline)) {
                    SortOptionButton(
                        title: "Newest First",
                        icon: "arrow.down.circle.fill",
                        isSelected: sortOption == .newestFirst
                    ) {
                        sortOption = .newestFirst
                    }
                    
                    SortOptionButton(
                        title: "Oldest First",
                        icon: "arrow.up.circle.fill",
                        isSelected: sortOption == .oldestFirst
                    ) {
                        sortOption = .oldestFirst
                    }
                }
                
                // Saved Filter Section
                Section(header: Text("Filters").font(.headline)) {
                    Toggle(isOn: $showOnlySaved) {
                        HStack {
                            Image(systemName: "bookmark.fill")
                                .foregroundColor(.yellow)
                            Text("Show Only Saved")
                        }
                    }
                    .tint(.yellow)
                }
                
                // Reset Section
                Section {
                    Button(action: resetFilters) {
                        HStack {
                            Spacer()
                            Image(systemName: "arrow.clockwise.circle.fill")
                            Text("Reset All Filters")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                        .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Timeline & Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: {
    ToolbarItem(placement: .navigationBarLeading) {
        Button("Reset") {
            resetFilters()
        }
        .foregroundColor(.red)
    }

    ToolbarItem(placement: .navigationBarTrailing) {
        Button("Done") {
            presentationMode.wrappedValue.dismiss()
        }
        .font(.system(size: 17, weight: .semibold))
    }
})

            .sheet(isPresented: $showCustomDatePicker) {
                CustomDateRangePicker(
                    startDate: $customStartDate,
                    endDate: $customEndDate,
                    onApply: {
                        timeFilter = .custom(startDate: customStartDate, endDate: customEndDate)
                        showCustomDatePicker = false
                    }
                )
            }
        }
    }
    
    private func resetFilters() {
        timeFilter = .all
        sortOption = .newestFirst
        showOnlySaved = false
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM dd, yyyy"
        return formatter.string(from: date)
    }
}

// MARK: - Time Filter Button

struct TimeFilterButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(isSelected ? .blue : .gray)
                
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

// MARK: - Sort Option Button

struct SortOptionButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(isSelected ? .green : .gray)
                
                Text(title)
                    .foregroundColor(.primary)
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            }
        }
    }
}

// MARK: - Custom Date Range Picker

struct CustomDateRangePicker: View {
    @Environment(\.presentationMode) var presentationMode
    
    @Binding var startDate: Date
    @Binding var endDate: Date
    let onApply: () -> Void
    
    @State private var showStartTimePicker = false
    @State private var showEndTimePicker = false
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Start Date & Time").font(.headline)) {
                    DatePicker(
                        "Date",
                        selection: $startDate,
                        in: ...Date(),
                        displayedComponents: .date
                    )
                    
                    Button(action: { showStartTimePicker.toggle() }) {
                        HStack {
                            Text("Time")
                                .foregroundColor(.primary)
                            Spacer()
                            Text(formatTime(startDate))
                                .foregroundColor(.blue)
                            Image(systemName: showStartTimePicker ? "chevron.up" : "chevron.down")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if showStartTimePicker {
                        DatePicker(
                            "Select Time",
                            selection: $startDate,
                            displayedComponents: .hourAndMinute
                        )
                        .datePickerStyle(WheelDatePickerStyle())
                    }
                }
                
                Section(header: Text("End Date & Time").font(.headline)) {
                    DatePicker(
                        "Date",
                        selection: $endDate,
                        in: startDate...Date(),
                        displayedComponents: .date
                    )
                    
                    Button(action: { showEndTimePicker.toggle() }) {
                        HStack {
                            Text("Time")
                                .foregroundColor(.primary)
                            Spacer()
                            Text(formatTime(endDate))
                                .foregroundColor(.blue)
                            Image(systemName: showEndTimePicker ? "chevron.up" : "chevron.down")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if showEndTimePicker {
                        DatePicker(
                            "Select Time",
                            selection: $endDate,
                            displayedComponents: .hourAndMinute
                        )
                        .datePickerStyle(WheelDatePickerStyle())
                    }
                }
                
                Section {
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(.blue)
                        Text("End date must be after start date")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Custom Date Range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: {
    ToolbarItem(placement: .navigationBarLeading) {
        Button("Cancel") {
            presentationMode.wrappedValue.dismiss()
        }
    }

    ToolbarItem(placement: .navigationBarTrailing) {
        Button("Apply") {
            if endDate >= startDate {
                onApply()
            }
        }
        .font(.system(size: 17, weight: .semibold))
        .disabled(endDate < startDate)
    }
})

        }
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Preview

struct ChannelDetailFilterSheet_Previews: PreviewProvider {
    static var previews: some View {
        ChannelDetailFilterSheet(
            timeFilter: .constant(.all),
            sortOption: .constant(.newestFirst),
            showOnlySaved: .constant(false),
            totalEventCount: 42,
            savedEventCount: 5
        )
    }
}
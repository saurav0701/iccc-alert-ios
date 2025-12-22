import SwiftUI

struct FilterSheetView: View {
    @ObservedObject var filterState: FilterState
    let availableAreas: [String]
    let availableEventTypes: [String]
    
    @Environment(\.presentationMode) var presentationMode
    
    @State private var isAreaExpanded = false
    @State private var isEventTypeExpanded = false
    @State private var isTimeExpanded = false
    @State private var showCustomDatePicker = false
    
    @State private var customStartDate = Calendar.current.startOfDay(for: Date())
    @State private var customEndDate = Date()
    @State private var customStartTime = Date()
    @State private var customEndTime = Date()
    
    var body: some View {
        NavigationView {
            List {
                // Time Filter Section
                Section {
                    DisclosureGroup(
                        isExpanded: $isTimeExpanded,
                        content: {
                            VStack(spacing: 12) {
                                timeFilterButton(.all, icon: "clock.fill", color: .gray)
                                timeFilterButton(.today, icon: "sun.max.fill", color: .orange)
                                timeFilterButton(.yesterday, icon: "moon.fill", color: .indigo)
                                
                                Button(action: { showCustomDatePicker = true }) {
                                    HStack {
                                        Image(systemName: "calendar")
                                            .foregroundColor(.blue)
                                        
                                        Text(customDateRangeText)
                                            .foregroundColor(.primary)
                                        
                                        Spacer()
                                        
                                        if case .custom = filterState.timeFilter {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.blue)
                                        }
                                    }
                                    .padding(.vertical, 8)
                                }
                            }
                        },
                        label: {
                            HStack {
                                Image(systemName: "clock.fill")
                                    .foregroundColor(.blue)
                                Text("Time Period")
                                    .font(.headline)
                                Spacer()
                                Text(filterState.timeFilter.displayText)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    )
                }
                
                // Area Filter Section
                Section {
                    DisclosureGroup(
                        isExpanded: $isAreaExpanded,
                        content: {
                            ForEach(availableAreas, id: \.self) { area in
                                MultipleSelectionRow(
                                    title: area,
                                    isSelected: filterState.selectedAreas.contains(area)
                                ) {
                                    toggle(&filterState.selectedAreas, value: area)
                                }
                            }
                        },
                        label: {
                            HStack {
                                Image(systemName: "map.fill")
                                    .foregroundColor(.green)
                                Text("Filter by Area")
                                    .font(.headline)
                                Spacer()
                                if !filterState.selectedAreas.isEmpty {
                                    Text("\(filterState.selectedAreas.count)")
                                        .font(.caption)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                        .frame(width: 24, height: 24)
                                        .background(Color.green)
                                        .clipShape(Circle())
                                }
                            }
                        }
                    )
                }

                // Event Type Filter Section
                Section {
                    DisclosureGroup(
                        isExpanded: $isEventTypeExpanded,
                        content: {
                            ForEach(availableEventTypes, id: \.self) { type in
                                MultipleSelectionRow(
                                    title: type,
                                    isSelected: filterState.selectedEventTypes.contains(type)
                                ) {
                                    toggle(&filterState.selectedEventTypes, value: type)
                                }
                            }
                        },
                        label: {
                            HStack {
                                Image(systemName: "tag.fill")
                                    .foregroundColor(.blue)
                                Text("Filter by Event Type")
                                    .font(.headline)
                                Spacer()
                                if !filterState.selectedEventTypes.isEmpty {
                                    Text("\(filterState.selectedEventTypes.count)")
                                        .font(.caption)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                        .frame(width: 24, height: 24)
                                        .background(Color.blue)
                                        .clipShape(Circle())
                                }
                            }
                        }
                    )
                }

                // Clear All Section
                Section {
                    Button(action: {
                        filterState.clearAll()
                    }) {
                        HStack {
                            Image(systemName: "xmark.circle.fill")
                            Text("Clear All Filters")
                        }
                        .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Advanced Filters")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button("Done") {
                presentationMode.wrappedValue.dismiss()
            }
            .font(.system(size: 17, weight: .semibold)))
            .sheet(isPresented: $showCustomDatePicker) {
                CustomDateTimePickerView(
                    startDate: $customStartDate,
                    endDate: $customEndDate,
                    startTime: $customStartTime,
                    endTime: $customEndTime,
                    onApply: {
                        let start = combineDateAndTime(date: customStartDate, time: customStartTime)
                        let end = combineDateAndTime(date: customEndDate, time: customEndTime)
                        filterState.timeFilter = .custom(startDate: start, endDate: end)
                        showCustomDatePicker = false
                    }
                )
            }
        }
    }
    
    private func timeFilterButton(_ filter: TimeFilter, icon: String, color: Color) -> some View {
        Button(action: {
            filterState.timeFilter = filter
        }) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                
                Text(filter.displayText)
                    .foregroundColor(.primary)
                
                Spacer()
                
                if filterState.timeFilter == filter {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.blue)
                }
            }
            .padding(.vertical, 8)
        }
    }
    
    private var customDateRangeText: String {
        if case .custom(let start, let end) = filterState.timeFilter {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return "\(formatter.string(from: start)) - \(formatter.string(from: end))"
        }
        return "Select Custom Range"
    }

    private func toggle(_ set: inout Set<String>, value: String) {
        if set.contains(value) {
            set.remove(value)
        } else {
            set.insert(value)
        }
    }
    
    private func combineDateAndTime(date: Date, time: Date) -> Date {
        let calendar = Calendar.current
        let dateComponents = calendar.dateComponents([.year, .month, .day], from: date)
        let timeComponents = calendar.dateComponents([.hour, .minute], from: time)
        
        var combined = DateComponents()
        combined.year = dateComponents.year
        combined.month = dateComponents.month
        combined.day = dateComponents.day
        combined.hour = timeComponents.hour
        combined.minute = timeComponents.minute
        
        return calendar.date(from: combined) ?? date
    }
}

// MARK: - Custom Date Time Picker

struct CustomDateTimePickerView: View {
    @Binding var startDate: Date
    @Binding var endDate: Date
    @Binding var startTime: Date
    @Binding var endTime: Date
    let onApply: () -> Void
    
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Start Date & Time")) {
                    DatePicker("Date", selection: $startDate, displayedComponents: .date)
                    DatePicker("Time", selection: $startTime, displayedComponents: .hourAndMinute)
                }
                
                Section(header: Text("End Date & Time")) {
                    DatePicker("Date", selection: $endDate, displayedComponents: .date)
                    DatePicker("Time", selection: $endTime, displayedComponents: .hourAndMinute)
                }
                
                Section {
                    Button(action: {
                        onApply()
                    }) {
                        HStack {
                            Spacer()
                            Text("Apply")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Custom Time Range")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(leading: Button("Cancel") {
                presentationMode.wrappedValue.dismiss()
            })
        }
    }
}
import SwiftUI
import SwiftData

/// Manage recurring windows the scheduler must leave alone.
struct BlockedTimeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BlockedTime.startHour) private var blockedTimes: [BlockedTime]
    @State private var showingAdd = false

    var body: some View {
        Group {
            if blockedTimes.isEmpty {
                ScrollView {
                    EmptyStateView(
                        icon: "lock",
                        title: "No blocked times",
                        subtitle: "Add classes, meetings, or commutes so Loom schedules around them.",
                        actionLabel: "Add blocked time",
                        action: { showingAdd = true }
                    )
                    .padding(.top, 60)
                }
                .background(Color.loomBackground)
            } else {
                List {
                    Section {
                        ForEach(blockedTimes) { blocked in
                            BlockedTimeRow(blocked: blocked)
                                .listRowBackground(Color.loomSurface)
                        }
                        .onDelete(perform: delete)
                    } header: {
                        Text("Recurring")
                            .font(AppFont.caption(12))
                            .foregroundStyle(Color.loomSubtle)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.loomBackground)
            }
        }
        .navigationTitle("Blocked Times")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(Color.brand500)
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddBlockedTimeSheet()
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(blockedTimes[index])
        }
    }
}

// MARK: - Row

private struct BlockedTimeRow: View {
    let blocked: BlockedTime

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.loomFaint)
                .frame(width: 4, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(blocked.label)
                    .font(AppFont.bodySemibold(14))
                    .foregroundStyle(Color.loomText)
                HStack(spacing: 4) {
                    Text(timeRange)
                        .font(AppFont.monoMedium(11))
                        .foregroundStyle(Color.loomSubtle)
                    Text("· \(blocked.repeatLabel)")
                        .font(AppFont.caption(11))
                        .foregroundStyle(Color.workColor)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var timeRange: String {
        let calendar = Calendar.current
        let base = calendar.startOfDay(for: Date())
        guard let start = calendar.date(
            bySettingHour: blocked.startHour, minute: blocked.startMinute, second: 0, of: base
        ) else { return "" }
        let end = start.addingTimeInterval(TimeInterval(blocked.durationMinutes * 60))
        return "\(TimeFormatter.clock.string(from: start)) – \(TimeFormatter.clock.string(from: end))"
    }
}

// MARK: - Add sheet

private struct AddBlockedTimeSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var selectedWeekdays: Set<Int> = [2, 3, 4, 5, 6]
    @State private var startTime = defaultStart()
    @State private var endTime = defaultEnd()

    private let weekdayOrder = [2, 3, 4, 5, 6, 7, 1] // Mon…Sun

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. CS 101 Lecture", text: $label)
                        .font(AppFont.bodySemibold(15))
                } header: {
                    Text("Name")
                }

                Section {
                    HStack(spacing: 6) {
                        ForEach(weekdayOrder, id: \.self) { weekday in
                            let letter = Calendar.current.veryShortWeekdaySymbols[weekday - 1]
                            let isOn = selectedWeekdays.contains(weekday)
                            Button {
                                if isOn {
                                    selectedWeekdays.remove(weekday)
                                } else {
                                    selectedWeekdays.insert(weekday)
                                }
                            } label: {
                                Text(letter)
                                    .font(AppFont.caption(12))
                                    .foregroundStyle(isOn ? .white : Color.loomText)
                                    .frame(width: 34, height: 34)
                                    .background(
                                        Circle().fill(isOn ? Color.brand500 : Color.loomSurface2)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity)
                } header: {
                    Text("Repeats on")
                }

                Section {
                    DatePicker("Starts", selection: $startTime, displayedComponents: .hourAndMinute)
                    DatePicker("Ends", selection: $endTime, displayedComponents: .hourAndMinute)
                } header: {
                    Text("Time")
                } footer: {
                    if durationMinutes <= 0 {
                        Text("End time must be after start time.")
                            .foregroundStyle(Color.loomRed)
                    }
                }
            }
            .navigationTitle("Blocked Time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.loomSubtle)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }
                        .foregroundStyle(Color.brand500)
                        .disabled(!isValid)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var durationMinutes: Int {
        let calendar = Calendar.current
        let start = calendar.dateComponents([.hour, .minute], from: startTime)
        let end = calendar.dateComponents([.hour, .minute], from: endTime)
        let startTotal = (start.hour ?? 0) * 60 + (start.minute ?? 0)
        let endTotal = (end.hour ?? 0) * 60 + (end.minute ?? 0)
        return endTotal - startTotal
    }

    private var isValid: Bool {
        !label.trimmingCharacters(in: .whitespaces).isEmpty
            && !selectedWeekdays.isEmpty
            && durationMinutes > 0
    }

    private func save() {
        let components = Calendar.current.dateComponents([.hour, .minute], from: startTime)
        let blocked = BlockedTime(
            label: label.trimmingCharacters(in: .whitespaces),
            weekdays: Array(selectedWeekdays).sorted(),
            startHour: components.hour ?? 9,
            startMinute: components.minute ?? 0,
            durationMinutes: durationMinutes
        )
        modelContext.insert(blocked)
        dismiss()
    }

    private static func defaultStart() -> Date {
        Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    }

    private static func defaultEnd() -> Date {
        Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date()) ?? Date()
    }
}

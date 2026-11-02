import SwiftUI
import UIKit

struct UsageCalendarSheet: View {
    let available: Set<String>
    let selected: String?
    let select: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                UsageCalendar(available: available, selected: selected) { day in
                    select(day)
                    dismiss()
                }
                Text("没有使用记录的日期已置灰，无法选择。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle("选择日期").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct UsageCalendar: UIViewRepresentable {
    let available: Set<String>
    let selected: String?
    let select: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UICalendarView {
        let view = UICalendarView()
        view.calendar = UsageDates.calendar
        view.timeZone = UsageDates.calendar.timeZone
        view.locale = Locale(identifier: "zh_CN")
        view.tintColor = .systemBlue
        view.selectionBehavior = UICalendarSelectionSingleDate(delegate: context.coordinator)
        update(view, initial: true)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }
    func updateUIView(_ view: UICalendarView, context: Context) {
        context.coordinator.parent = self
        update(view, initial: false)
    }
    private func update(_ view: UICalendarView, initial: Bool) {
        let dates = available.compactMap(UsageDates.date).sorted()
        if let first = dates.first, let last = dates.last {
            view.availableDateRange = DateInterval(start: first, end: last.addingTimeInterval(86_399))
        }
        if let day = selected, available.contains(day), let date = UsageDates.date(day),
           let selection = view.selectionBehavior as? UICalendarSelectionSingleDate {
            let components = UsageDates.calendar.dateComponents([.year, .month, .day], from: date)
            if selection.selectedDate != components { selection.setSelected(components, animated: false) }
            if initial { view.setVisibleDateComponents(components, animated: false) }
        }
    }
    final class Coordinator: NSObject, UICalendarSelectionSingleDateDelegate {
        var parent: UsageCalendar
        init(_ parent: UsageCalendar) { self.parent = parent }
        func dateSelection(_ selection: UICalendarSelectionSingleDate, canSelectDate dateComponents: DateComponents?) -> Bool {
            guard let dateComponents else { return false }
            return UsageDates.canSelect(dateComponents, available: parent.available)
        }
        func dateSelection(_ selection: UICalendarSelectionSingleDate, didSelectDate dateComponents: DateComponents?) {
            guard let dateComponents, UsageDates.canSelect(dateComponents, available: parent.available),
                  let day = UsageDates.key(dateComponents) else { return }
            parent.select(day)
        }
    }
}

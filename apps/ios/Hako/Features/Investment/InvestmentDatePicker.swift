import SwiftUI
import UIKit

struct InvestmentDatePicker: View {
    let title: String
    @Binding var selection: Date
    private let range: ClosedRange<Date>
    @Environment(\.locale) private var locale
    @State private var showsCalendar = false

    init(_ title: String, selection: Binding<Date>, earliest: Date = .distantPast, latest: Date = .distantFuture) {
        self.title = title
        _selection = selection
        range = InvestmentBook.day(earliest)...InvestmentBook.day(latest)
    }

    private var dateLabel: String {
        var format = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)
        format.calendar = InvestmentBook.calendar
        format.timeZone = InvestmentBook.calendar.timeZone
        return selection.formatted(format)
    }

    var body: some View {
        Button { showsCalendar = true } label: {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                Text(dateLabel)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(dateLabel)
        .investmentListRow()
        .sheet(isPresented: $showsCalendar) {
            SettingsSheet(title: title, detents: [.height(440), .large]) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("当前日期 · " + dateLabel)
                            .font(.subheadline).foregroundStyle(.secondary)
                        InvestmentDayCalendar(day: selection, range: range, locale: locale) { day in
                            selection = day
                            showsCalendar = false
                        }
                        .frame(minHeight: 320)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
            }
        }
    }
}

private struct InvestmentDayCalendar: UIViewRepresentable {
    let day: Date
    let range: ClosedRange<Date>
    let locale: Locale
    let select: (Date) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UICalendarView {
        let calendar = InvestmentBook.calendar
        let view = UICalendarView()
        view.calendar = calendar
        view.timeZone = calendar.timeZone
        view.locale = locale
        view.availableDateRange = DateInterval(start: range.lowerBound,
                                               end: InvestmentBook.addDays(1, to: range.upperBound).addingTimeInterval(-1))
        let visibleDay = min(max(InvestmentBook.day(day), range.lowerBound), range.upperBound)
        view.setVisibleDateComponents(calendar.dateComponents([.year, .month, .day], from: visibleDay), animated: false)
        // Begin without an active UIKit selection so tapping the current form date also emits a day selection.
        view.selectionBehavior = UICalendarSelectionSingleDate(delegate: context.coordinator)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    func updateUIView(_ view: UICalendarView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UICalendarSelectionSingleDateDelegate {
        var parent: InvestmentDayCalendar

        init(_ parent: InvestmentDayCalendar) { self.parent = parent }

        func dateSelection(_ selection: UICalendarSelectionSingleDate, canSelectDate components: DateComponents?) -> Bool {
            validDay(components) != nil
        }

        func dateSelection(_ selection: UICalendarSelectionSingleDate, didSelectDate components: DateComponents?) {
            if let day = validDay(components) { parent.select(day) }
        }

        private func validDay(_ components: DateComponents?) -> Date? {
            guard let components, let date = InvestmentBook.calendar.date(from: components) else { return nil }
            let day = InvestmentBook.day(date)
            return parent.range.contains(day) ? day : nil
        }
    }
}

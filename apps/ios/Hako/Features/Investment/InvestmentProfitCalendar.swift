import SwiftUI

struct InvestmentProfitCalendar: View {
    private struct Request: Equatable, Sendable {
        let version: UUID
        let year: Date
        let today: Date
    }
    private struct Loaded {
        let request: Request
        let data: InvestmentProfitCalendarData
    }

    let book: InvestmentBook
    let bookVersion: UUID
    @AppStorage("investment.overview.profitCalendar.monthly") private var showsMonths = false
    @State private var period = InvestmentBook.day()
    @State private var selectedDay = InvestmentBook.day()
    @State private var loaded: Loaded?

    private var today: Date { InvestmentBook.day() }
    private var calendar: Calendar { InvestmentBook.calendar }
    private var year: Date { calendar.dateInterval(of: .year, for: period)!.start }
    private var month: Date { calendar.dateInterval(of: .month, for: period)!.start }
    private var firstYear: Date { calendar.dateInterval(of: .year, for: min(book.earliest ?? today, today))!.start }

    var body: some View {
        let request = Request(version: bookVersion, year: year, today: today)
        let data = loaded?.request == request ? loaded?.data : nil
        let selected = data?.months.first { $0.start == month }
        return InvestmentCard {
            header
            if let data, let selected {
                let summary = showsMonths ? data.summary : selected.summary
                periodSummary(summary)
                if showsMonths { months(data.months) }
                else { days(selected, gains: data.dailyGains) }
                Divider().padding(.top, 5)
                if showsMonths { monthDetail(selected) }
                else { dayDetail(data.dailyGains[selectedDay]) }
            } else {
                ProgressView("正在汇总盈亏…").font(.caption)
                    .frame(maxWidth: .infinity, minHeight: 300)
            }
            Text("按人民币汇总每日盈亏，资金进出不计入收益。当前月份含今日暂估；缺少完整估值时显示「—」。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .task(id: request) { await load(request) }
        .onChange(of: book.earliest) {
            let first = calendar.dateInterval(of: .month, for: book.earliest ?? today)!.start
            if month < first { period = min(book.earliest ?? today, today); selectedDay = period }
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                viewMenu.fixedSize()
                Spacer(minLength: 4)
                navigation.fixedSize()
            }
            VStack(alignment: .leading, spacing: 3) {
                viewMenu
                navigation.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var viewMenu: some View {
        Menu {
            Picker("盈亏查看方式", selection: $showsMonths) {
                Text("盈亏日历").tag(false)
                Text("盈亏月历").tag(true)
            }
        } label: {
            HStack(spacing: 6) {
                Text(showsMonths ? "盈亏月历" : "盈亏日历").font(.headline)
                Image(systemName: "chevron.down").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).tint(.primary)
        .accessibilityLabel("切换盈亏日历或月历，当前为" + (showsMonths ? "月历" : "日历"))
    }

    private var navigation: some View {
        HStack(spacing: 2) {
            Button { move(-1) } label: {
                Image(systemName: "chevron.left").frame(width: 32, height: 44)
            }
            .accessibilityLabel(showsMonths ? "上一年" : "上个月")
            .disabled(showsMonths ? year <= firstYear : month <= calendar.dateInterval(of: .month, for: book.earliest ?? today)!.start)
            Text(String(calendar.component(.year, from: period)) + "年" +
                 (showsMonths ? "" : String(calendar.component(.month, from: period)) + "月"))
                .font(.caption).monospacedDigit()
            Button { move(1) } label: {
                Image(systemName: "chevron.right").frame(width: 32, height: 44)
            }
            .accessibilityLabel(showsMonths ? "下一年" : "下个月")
            .disabled(calendar.isDate(period, equalTo: today, toGranularity: showsMonths ? .year : .month))
        }.buttonStyle(.plain)
    }

    private func periodSummary(_ summary: InvestmentProfitCalendarData.Summary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom) {
                InvestmentMetric(title: showsMonths ? "年度累计盈亏" : "本月累计盈亏",
                                 value: amount(summary.gain), prominent: true)
                Spacer(minLength: 4)
                Text("单位：CNY").font(.caption2).foregroundStyle(.secondary)
            }
            if summary.missingDays > 0 {
                Text("缺少 \(summary.missingDays) 天完整估值，暂不汇总。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.bottom, 7)
    }

    private func months(_ months: [InvestmentProfitCalendarData.Month]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(months) { item in
                let gain = item.summary.gain
                let color = InvestmentText.tint(gain)
                let current = calendar.isDate(item.start, equalTo: today, toGranularity: .month)
                let active = item.start == month
                Button { selectMonth(item) } label: {
                    VStack(spacing: 5) {
                        Text("\(item.number)月").font(.caption)
                        Text(amount(gain)).font(.subheadline.weight(.medium)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.65)
                        if current {
                            Text("截至\(calendar.component(.day, from: today))日").font(.caption2).foregroundStyle(.secondary)
                        } else if item.summary.missingDays > 0 {
                            Text("缺\(item.summary.missingDays)天").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(item.start > today ? Color.secondary : color)
                    .padding(.horizontal, 3).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 78)
                    .background(color.opacity(gain == nil || gain == 0 ? 0.04 : 0.1), in: RoundedRectangle(cornerRadius: 9))
                    .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(active ? Color.primary : .clear, lineWidth: 1.5) }
                }
                .buttonStyle(.plain).disabled(item.start > today || item.summary.expectedDays == 0)
                .accessibilityLabel("\(item.number)月，" + (item.summary.expectedDays == 0 ? "暂无记录" :
                    "盈亏 " + InvestmentText.money(gain, .cny, signed: true) +
                    (item.summary.missingDays > 0 ? "，缺少\(item.summary.missingDays)天完整估值" : "")))
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
    }

    private func days(_ month: InvestmentProfitCalendarData.Month, gains: [Date: Decimal]) -> some View {
        let offset = (calendar.component(.weekday, from: month.start) + 5) % 7
        let count = calendar.range(of: .day, in: .month, for: month.start)!.count
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 3) {
            ForEach(Array("一二三四五六日"), id: \.self) {
                Text(String($0)).font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(0..<offset, id: \.self) { _ in Color.clear.frame(height: 44) }
            ForEach(0..<count, id: \.self) { index in
                let day = InvestmentBook.addDays(index, to: month.start)
                dayTile(day, label: index + 1, gain: gains[day])
            }
        }
    }

    private func dayTile(_ day: Date, label: Int, gain: Decimal?) -> some View {
        let color = InvestmentText.tint(gain)
        let active = day == selectedDay
        return Button { selectedDay = day } label: {
            VStack(spacing: 2) {
                Text(String(label))
                if let gain { Text(compact(gain)).lineLimit(1).minimumScaleFactor(0.65) }
                else if day <= today, let earliest = book.earliest, day >= earliest { Text("—").foregroundStyle(.secondary) }
            }
            .font(.caption2).monospacedDigit()
            .foregroundStyle(day > today ? Color.secondary : color)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(color.opacity(gain == nil || gain == 0 ? 0 : 0.1), in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(active ? Color.primary : .clear) }
        }
        .buttonStyle(.plain).disabled(day > today)
        .accessibilityLabel(InvestmentText.date(day) + "，盈亏 " + InvestmentText.money(gain, .cny, signed: true))
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func monthDetail(_ month: InvestmentProfitCalendarData.Month) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("\(month.number)月累计盈亏").font(.caption)
                Spacer(minLength: 5)
                Text(amount(month.summary.gain)).font(.subheadline.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(InvestmentText.tint(month.summary.gain))
            }
            if let last = month.summary.last {
                Text("截至" + InvestmentText.date(last) + " · \(month.summary.recordedDays)个完整记录日" +
                     (last == today && month.summary.gain != nil ? " · 含今日暂估" : ""))
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("暂无账本记录").font(.caption2).foregroundStyle(.secondary)
            }
            if month.summary.missingDays > 0 {
                Text("缺少 \(month.summary.missingDays) 天完整估值" +
                     (month.summary.knownGain.map { "；已知日期盈亏 " + InvestmentText.money($0, .cny, signed: true) } ?? ""))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button {
                showsMonths = false
            } label: {
                HStack { Text("查看\(month.number)月日历"); Spacer(); InvestmentChevron() }
                    .font(.caption).frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(month.summary.expectedDays == 0)
        }
    }

    private func dayDetail(_ gain: Decimal?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(InvestmentText.date(selectedDay) + (selectedDay == today ? " · 暂估盈亏" : " · 当日盈亏"))
                Spacer(minLength: 4)
                Text(amount(gain)).foregroundStyle(InvestmentText.tint(gain)).monospacedDigit()
            }.font(.caption)
            if gain == nil { Text("缺少日行情、汇率或账本记录").font(.caption2).foregroundStyle(.secondary) }
        }
    }

    private func amount(_ gain: Decimal?) -> String {
        guard let gain else { return "—" }
        return (gain > 0 ? "+" : "") + gain.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).precision(.fractionLength(2)))
    }

    private func compact(_ gain: Decimal) -> String {
        let sign = gain > 0 ? "+" : ""
        if abs(gain) >= 1_000 {
            return sign + (gain / 1_000).formatted(.number.locale(Locale(identifier: "en_US_POSIX"))
                .grouping(.never).precision(.fractionLength(1))) + "k"
        }
        return sign + gain.formatted(.number.precision(.fractionLength(0...1)))
    }

    private func selectMonth(_ month: InvestmentProfitCalendarData.Month) {
        period = month.start
        selectedDay = min(today, month.end)
    }

    private func move(_ offset: Int) {
        guard let next = calendar.date(byAdding: showsMonths ? .year : .month, value: offset, to: period) else { return }
        period = min(next, today)
        selectedDay = period
    }

    private func load(_ request: Request) async {
        guard loaded?.request != request else { return }
        let book = book
        let worker = Task.detached(priority: .userInitiated) {
            InvestmentProfitCalendarData(book: book, yearContaining: request.year, today: request.today)
        }
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled else { return }
        loaded = Loaded(request: request, data: result)
    }
}

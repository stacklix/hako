import SwiftUI

struct InvestmentTransactionRecords: View {
    @ObservedObject var store: InvestmentStore
    let account: InvestmentAccount
    let asset: InvestmentAsset
    @State private var expandedID: UUID?
    @State private var showsAll = false
    @State private var editing: InvestmentEvent?
    private var book: InvestmentBook { store.book }
    private var events: [InvestmentEvent] {
        Array(book.orderedEvents(account, through: InvestmentBook.day()).filter { $0.assetID == asset.id }.reversed())
    }
    private func isSpotAdjustment(_ event: InvestmentEvent) -> Bool {
        asset.kind == .crypto && [.stakingReward, .spotAdjustment].contains(event.kind)
    }
    private func title(_ event: InvestmentEvent) -> String { isSpotAdjustment(event) ? "余额调整" : book.eventTitle(event, accountID: account.id) }
    private func quantity(_ value: Decimal, signed: Bool = false) -> String {
        (signed && value > 0 ? "+" : "") + InvestmentText.number(value) + " " + asset.historyUnit
    }

    var body: some View {
        let records = events
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("交易记录").font(.headline)
                Spacer()
                Text("共 \(records.count) 笔").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 4)
            InvestmentCard {
                if records.isEmpty {
                    Text("暂无交易记录").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(Array((showsAll ? records : Array(records.prefix(4))).enumerated()), id: \.element.id) { index, event in
                    if index > 0 { Divider() }
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { expandedID = expandedID == event.id ? nil : event.id }
                    } label: {
                        record(event)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(title(event) + "，" + InvestmentText.date(event.day))
                    .accessibilityValue(expandedID == event.id ? "明细已展开" : "明细已收起")
                    .accessibilityHint("点击展开明细，同时收起其他记录。")
                    if expandedID == event.id { details(event) }
                }
                if records.count > 4 {
                    Divider()
                    Button(showsAll ? "收起较早交易" : "展开其余 \(records.count - 4) 笔交易") { showsAll.toggle() }
                        .font(.caption).foregroundStyle(InvestmentBalanceStyle.accent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .buttonStyle(.plain)
                }
            }
        }
        .onChange(of: store.bookVersion) {
            if let expandedID, !events.contains(where: { $0.id == expandedID }) { self.expandedID = nil }
        }
        .sheet(item: $editing) { event in
            InvestmentEventEditor(store: store, accountID: account.id, event: event)
        }
    }

    private func record(_ event: InvestmentEvent) -> some View {
        let buy = event.kind == .buy || event.kind == .opening
        let sell = event.kind == .sell
        let color = buy ? Color.green : sell ? Color.red : InvestmentBalanceStyle.accent
        let symbol = buy ? "买" : sell ? "卖" : isSpotAdjustment(event) ? "调" : event.kind == .bonusShares ? "送" : event.kind == .dividend ? "分" : "记"
        return HStack(spacing: 10) {
            Text(symbol).font(.caption).foregroundStyle(color)
                .frame(width: 30, height: 30).background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(title(event)).font(.subheadline.weight(.medium))
                Text(InvestmentText.date(event.day)).font(.caption2).foregroundStyle(.secondary)
                if isSpotAdjustment(event) {
                    Text((event.quantity > 0 ? "增加 " : "减少 ") + quantity(abs(event.quantity)))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                summary(event)
            }.font(.subheadline).monospacedDigit().multilineTextAlignment(.trailing)
            Image(systemName: expandedID == event.id ? "chevron.down" : "chevron.right")
                .font(.caption2).foregroundStyle(.tertiary).accessibilityHidden(true)
        }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
    }

    @ViewBuilder private func summary(_ event: InvestmentEvent) -> some View {
        switch event.kind {
        case .insuranceWithdrawal:
            Text(InvestmentText.money(event.amount, account.currency))
            secondary("转入账户现金")
        case .stakingReward, .spotAdjustment:
            let balance = book.positionBefore(event, accountID: account.id).map { $0.quantity + event.quantity }
            Text(balance.map { quantity($0) } ?? quantity(event.quantity, signed: true))
            secondary("调整后余额")
        case .dividend:
            Text(InvestmentText.money(event.amount, account.currency, signed: true))
            secondary("实际到账")
        case .bonusShares:
            Text(quantity(event.quantity, signed: true))
            secondary("持仓数量增加")
        case .opening, .buy, .sell:
            if asset.kind.usesBalance {
                Text(InvestmentText.money(event.price, account.currency))
                secondary(event.kind == .sell ? "实际回款" : "投入金额")
            } else {
                if asset.kind != .insurance { Text(quantity(event.quantity)) }
                secondary("成交价 " + InvestmentText.number(event.price) + " " + book.quoteUnit(for: asset))
            }
        case .adjustment where asset.kind.usesBalance:
            Text(InvestmentText.money(event.settledAmount, account.currency))
            secondary("调整后余额")
        default:
            Text(InvestmentText.money(event.amount, account.currency, signed: true))
        }
    }

    private func secondary(_ text: String) -> some View { Text(text).font(.caption2).foregroundStyle(.secondary) }

    private func details(_ event: InvestmentEvent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack {
                Text("交易明细").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("修改") { editing = event }
                    .font(.caption).foregroundStyle(InvestmentBalanceStyle.accent)
                    .frame(minWidth: 44, minHeight: 32, alignment: .trailing)
                    .buttonStyle(.plain).disabled(account.isArchived || store.saving)
                    .accessibilityLabel("修改" + title(event))
            }
            detailRow("记录类型", title(event))
            detailRow(isSpotAdjustment(event) ? "调整日期" : [.dividend, .bonusShares].contains(event.kind) ? "到账日期" : "交易日期",
                      InvestmentText.date(event.day))
            detailFields(event)
        }
    }

    @ViewBuilder private func detailFields(_ event: InvestmentEvent) -> some View {
        let cash = book.cashChange(for: event, accountID: account.id)
        switch event.kind {
        case .insuranceWithdrawal:
            detailRow("提取金额", InvestmentText.money(event.amount, account.currency))
            detailRow("到账账户", account.name + " · 现金")
            if let balance = event.settledAmount {
                detailRow("提取后现金价值", InvestmentText.money(balance, account.currency))
            } else {
                secondary("未填写现金价值，按最近已知现金价值扣减；缺少可用估值时待补充。")
            }
            secondary("保单继续保留；提取回款与剩余现金价值共同计算累计盈亏。")
        case .stakingReward, .spotAdjustment:
            let before = book.positionBefore(event, accountID: account.id)
            detailRow("调整前余额", before.map { quantity($0.quantity) } ?? "—")
            detailRow("调整后余额", before.map { quantity($0.quantity + event.quantity) } ?? "—")
            detailRow("数量变化", quantity(event.quantity, signed: true))
            detailRow("变动类型", event.kind.rawValue)
            let price = book.positionQuote(for: asset, on: event.day, requiresDailyPrices: event.day < InvestmentBook.day())
            detailRow("估值变动", InvestmentText.money(price.map { $0.price * event.quantity }, asset.currency, signed: true))
            secondary("按当日价格估值，计入累计盈亏；不产生现金收支。")
        case .dividend:
            detailRow("实际到账金额", InvestmentText.money(event.amount, account.currency, signed: true))
            detailRow("到账账户", account.name)
            detailRow("持仓数量变化", quantity(0))
            secondary("分红计入累计盈亏；除息引起的市值变化按当日行情计算。")
        case .bonusShares:
            let before = book.positionBefore(event, accountID: account.id)
            detailRow("送股数量", quantity(event.quantity, signed: true))
            detailRow("送股前持仓", before.map { quantity($0.quantity) } ?? "—")
            detailRow("送股后持仓", before.map { quantity($0.quantity + event.quantity) } ?? "—")
            detailRow("现金变化", InvestmentText.money(cash, account.currency, signed: true))
            secondary("送股增加持仓数量，不增加买入投入。")
        case .opening, .buy, .sell:
            if !asset.kind.usesBalance && asset.kind != .insurance { detailRow("成交数量", quantity(event.quantity)) }
            detailRow(asset.kind.usesBalance ? "变动金额" : "成交价格", InvestmentText.number(event.price) + " " + book.quoteUnit(for: asset))
            if asset.kind.supportsTradeFees { detailRow("交易费用", InvestmentText.money(event.fee ?? 0, asset.settlementCurrency)) }
            detailRow(event.kind == .opening ? "现金变化" : event.kind == .sell ? "实际回款" : "实际支出",
                      InvestmentText.money(cash.map(abs), account.currency))
            if let balance = event.settledAmount { detailRow(asset.kind.usesBalance ? "变动后余额" : "实际交收金额", InvestmentText.money(balance, account.currency)) }
            if asset.kind.usesMargin { detailRow("保证金", InvestmentText.money(event.margin, account.currency)) }
        case .adjustment where asset.kind.usesBalance:
            detailRow("调整前余额", InvestmentText.money(book.positionBefore(event, accountID: account.id)?.depositBalance, account.currency))
            detailRow("调整后余额", InvestmentText.money(event.settledAmount, account.currency))
        default:
            detailRow("变动金额", InvestmentText.money(event.amount, account.currency, signed: true))
            if let balance = event.settledAmount { detailRow("变动后余额", InvestmentText.money(balance, account.currency)) }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }.font(.caption).frame(maxWidth: .infinity)
    }
}

import SwiftUI

enum StockTradeGuideTopic: String, CaseIterable, Identifiable {
    case workflow = "业务流程", strategies = "选股策略", terms = "术语说明"
    var id: String {
        switch self { case .workflow: "workflow"; case .strategies: "strategies"; case .terms: "terms" }
    }
    var subtitle: String {
        switch self {
        case .workflow: "从行情到完整结果"
        case .strategies: "初选、复评与名单分层"
        case .terms: "指标、评分与任务状态"
        }
    }
}

/// Read-only guidance. Opening this view never fetches data or starts a workflow.
struct StockTradeGuideView: View {
    let topic: StockTradeGuideTopic
    @ObservedObject var store: StockTradeStore
    @State private var query = ""

    var body: some View {
        StockTradeScreen {
            switch topic {
            case .workflow: workflow
            case .strategies: strategies
            case .terms: glossary
            }
        }
        .navigationTitle(topic.rawValue).navigationBarTitleDisplayMode(.inline)
        .tint(StockTradeAppearance.tint)
    }

    private var workflow: some View {
        Group {
            StockTradeHeading(title: "一轮选股如何完成", subtitle: "更新数据 → 找候选 → 逐票复评 → 完整发布")
            StockTradeCard {
                Label("在工作台确认启动", systemImage: "play.circle").font(.headline)
                Text("“完整选股并发布”会依次执行下面四步。打开页面、下拉刷新或阅读本说明都不会启动选股。")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.top, 8)
            }
            ForEach(Array(StockTradeGuideContent.workflow.enumerated()), id: \.offset) { index, step in
                StockTradeGuideStep(number: index + 1, title: step.title, summary: step.detail,
                                    output: step.output, last: index == StockTradeGuideContent.workflow.count - 1)
            }
            StockTradeSectionLabel(title: "完成与异常分支")
            StockTradeCard {
                StockTradeGuideNote(symbol: "checkmark.circle", title: "校验通过 → 新结果可见",
                    detail: "发布生成独立快照，选股页读取已发布结果。历史结果仍可查看，较早日期的补跑不会替换较新日期的最新结果。")
                Divider().padding(.vertical, 12)
                StockTradeGuideNote(symbol: "exclamationmark.circle", title: "任一步失败 → 本轮不发布",
                    detail: "后续步骤停止，上一次完整结果继续可用。任务记录保留失败阶段与日志；重新运行会创建新任务。")
                Divider().padding(.vertical, 12)
                StockTradeGuideNote(symbol: "clock", title: "执行中 → 可以离开页面",
                    detail: "任务由后台持续执行。进度区报告处理数量、限流重试和无业务进展时长；某一步的百分比不代表整轮百分比。")
            }
            StockTradeSectionLabel(title: "选股结果之后")
            StockTradeCard {
                StockTradeGuideNote(symbol: "waveform.path.ecg", title: "关注、监控与纸面模拟",
                    detail: "关注是本机收藏；后台监控与纸面持仓使用各自的状态和规则。选股完成不等于已下单，监控也不是完整选股任务的第五步。")
            }
            StockTradeFootnote(text: "分步操作只执行选中的一步。单独更新行情、初选或复评，不会自动把结果发布到选股页。")
            glossaryLink
        }
    }

    private var strategies: some View {
        Group {
            StockTradeHeading(title: "先筛选，再复评和排序", subtitle: "初选解决“看哪些”，复评解决“为何入选、有哪些风险”")
            StockTradeCard {
                StockTradeGuideNote(symbol: "line.3.horizontal.decrease", title: "先建立流动性池",
                    detail: "按滚动成交额指标从高到低选择股票，再运行初选策略。当前实现参考配置为近 43 根日线、最多 2000 只；该指标用开收盘均价 × 成交量近似成交额，并非换手率。")
            }
            StockTradeFootnote(text: "下方策略数值为本版核对的后台参考配置，不是实时配置读取。部署端可以调整开关与参数；这份结果携带的实际推荐门槛见页末。")
            StockTradeSectionLabel(title: "第一层 · 策略初选")
            strategyCard("B1 · 趋势中的回撤", badge: "参考配置启用", summary: "寻找较长趋势仍偏多、短期动量处于低位的候选。", conditions: [
                "动量低位：KDJ 的 J < 15，或不高于截至当日历史 J 值的 10% 分位。",
                "日线趋势：收盘价和知行短期线都高于知行多空线；多空线参考周期为 14／28／57／114。",
                "周线趋势：采用策略中的 10／20／30 周均线多头约束；它与图表可选的 MA 线不是同一组参数。",
                "量价检查：近 20 根最大成交量日不能呈现策略定义的阴线破坏；同时记录前期异动、缩量回撤与涨幅等质量证据。"
            ])
            strategyCard("B2 · 回撤后的量价确认", badge: "参考配置启用", summary: "先有 B1 证据，再看后续是否出现量价确认；不是必须先进入当天 B1 名单。", conditions: [
                "过去 20 根日线内出现过 B1 信号，不包含当日。",
                "当日相对前收盘上涨至少 4%，成交量至少为前一日的 1.2 倍。",
                "J < 55，上影线占当日高低价区间不超过 45%。",
                "继续满足知行线与周线多头约束。B1、B2 候选合并后按代码去重。"
            ])
            strategyCard("Brick · 砖型图形态", badge: "参考配置关闭", summary: "实现中还包含红绿柱转换、柱体增长和趋势约束的形态策略。", conditions: [
                "当前核对的配置没有启用 Brick，不能把它当作每轮都会执行的初选条件。",
                "启用时由后台参数决定柱型、知行线和周线条件；本机说明页不修改这些开关。"
            ])
            StockTradeSectionLabel(title: "第二层 · 逐票复评")
            StockTradeCard {
                StockTradeGuideNote(symbol: "checklist", title: "先检查资格，再运行评分卡",
                    detail: "复评前检查 ST、上市时间、停牌、成交额以及市场和行业条件。初选阶段的部分质量与市场证据用于标注；进入复评后，前置过滤失败会形成排除结论。")
                Divider().padding(.vertical, 12)
                Text("规则评分的四个维度").font(.headline).padding(.bottom, 12)
                scoreDimension("趋势结构", weight: 20, detail: "均线方向、趋势延续与结构变化")
                scoreDimension("价格位置", weight: 20, detail: "相对高低点、支撑和追高程度")
                scoreDimension("量价表现", weight: 30, detail: "上涨放量、回撤缩量及放量阴线")
                scoreDimension("前期异动", weight: 30, detail: "此前放量阳线及其后续承接")
                Text("当前复评使用确定性代码，不读取图像、不调用 AI 模型。规则评分通常为 1～5 分，不能解释为胜率。")
                    .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
            }
            StockTradeCard {
                StockTradeGuideNote(symbol: "arrow.up.arrow.down", title: "规则评分 → 入池；排序分 → 排序",
                    detail: "排序分为 0～100，综合形态、异动动量、相对强度、资金流、市场行业与执行质量，并扣除风险分。它与 1～5 分的规则评分不是同一套分数。")
                Divider().padding(.vertical, 12)
                StockTradeGuideNote(symbol: "hand.raised", title: "风险检查可以直接排除",
                    detail: "跌停、炸板、破坏性放量阴线、小市值和严重 B1 质量风险等可触发一票否决；不能靠其他高分抵消。风险分是规则累计惩罚，不是亏损概率。")
            }
            StockTradeSectionLabel(title: "第三层 · 名单分层")
            StockTradeCard {
                ForEach(Array(StockTradeGuideContent.pools.enumerated()), id: \.offset) { index, item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.subheadline.weight(.semibold))
                        Text(item.detail).font(.footnote).foregroundStyle(.secondary)
                    }.padding(.vertical, 10)
                    if index < StockTradeGuideContent.pools.count - 1 { Divider() }
                }
            }
            StockTradeFootnote(text: "观察名单不等于正式推荐，部分范围可能重叠。进取观察的形态例外需要额外证据，不能把最低排序分 55 理解为单独的入选条件。")
            currentParameters
            glossaryLink
        }
    }

    private func strategyCard(_ title: String, badge: String, summary: String, conditions: [String]) -> some View {
        StockTradeCard {
            ViewThatFits(in: .horizontal) {
                HStack { Text(title).font(.headline); Spacer(); Text(badge).font(.caption).foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 6) { Text(title).font(.headline); Text(badge).font(.caption).foregroundStyle(.secondary) }
            }
            Text(summary).font(.subheadline).foregroundStyle(.secondary).padding(.top, 8)
            DisclosureGroup("查看筛选条件") {
                ForEach(conditions, id: \.self) { condition in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").accessibilityHidden(true)
                        Text(condition).frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.subheadline).padding(.top, 10)
                }
            }.font(.subheadline).padding(.top, 12)
        }
    }

    private func scoreDimension(_ title: String, weight: Int, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(title); Spacer(); Text("权重 \(weight)%").foregroundStyle(.secondary) }.font(.subheadline)
            ProgressView(value: Double(weight), total: 100).tint(StockTradeAppearance.tint).accessibilityLabel("\(title)权重 \(weight)%")
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }.padding(.bottom, 12)
    }

    @ViewBuilder private var currentParameters: some View {
        StockTradeSectionLabel(title: "这份结果使用的参数")
        StockTradeCard {
            if let run = store.run {
                Text(store.displayedRunID == nil ? "当前载入结果" : "所选历史结果").font(.headline)
                Text("数据日期 · " + run.dataAsOf).font(.footnote).foregroundStyle(.secondary).padding(.top, 6)
                Text("发布时间 · " + StockTradeTime.display(run.publishedAt)).font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                if run.stale { Text("后台标记这份结果需要更新。").font(.footnote).foregroundStyle(.orange).padding(.top, 6) }
                DisclosureGroup("查看本轮已发布门槛") { StockTradeFields(fields: run.thresholds).padding(.top, 8) }
                    .font(.subheadline).padding(.top, 12)
                Text("这里读取已载入快照，不代表后台正在编辑的配置，也不改变历史结果。").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            } else {
                Text("尚未载入已发布结果").font(.headline)
                Text("先在选股页载入一份完整结果，再回来查看该结果携带的实际门槛。参考说明仍可离线阅读。")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.top, 8)
            }
        }
    }

    private var glossaryLink: some View {
        StockTradeCard {
            NavigationLink { StockTradeGuideView(topic: .terms, store: store) }
            label: { StockTradeEntryRow(title: "术语说明", subtitle: "查看指标和评分含义", separator: false) }.buttonStyle(.plain)
        }
    }

    private var matchingTerms: [StockTradeGuideContent.Term] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return StockTradeGuideContent.terms.filter {
            keyword.isEmpty || ($0.title + " " + $0.english + " " + $0.detail).localizedStandardContains(keyword)
        }
    }
    private var glossary: some View {
        Group {
            StockTradeHeading(title: "读懂页面上的名词", subtitle: "按含义分组，也可以搜索中文或英文名称")
            StockTradeCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("搜索术语").font(.subheadline).foregroundStyle(.secondary)
                    TextField("如 B1、复权、排序分", text: $query).accessibilityLabel("搜索选股术语")
                        .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                }
                if !query.isEmpty { Button("清除搜索") { query = "" }.font(.footnote).padding(.top, 10) }
            }
            Text("共 \(matchingTerms.count) 个术语").font(.caption).foregroundStyle(.secondary)
            ForEach(StockTradeGuideContent.categories, id: \.self) { category in
                let terms = matchingTerms.filter { $0.category == category }
                if !terms.isEmpty {
                    StockTradeSectionLabel(title: category)
                    StockTradeCard {
                        ForEach(Array(terms.enumerated()), id: \.element.id) { index, term in
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(term.english).font(.caption).foregroundStyle(.secondary)
                                    Text(term.detail).font(.subheadline).textSelection(.enabled)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                            } label: { Text(term.title).font(.subheadline) }
                                .padding(.vertical, 10)
                            if index < terms.count - 1 { Divider() }
                        }
                    }
                }
            }
            if matchingTerms.isEmpty { ContentUnavailableView.search(text: query) }
        }
    }
}

private struct StockTradeGuideNote: View {
    let symbol, title, detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.body).frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct StockTradeGuideStep: View {
    let number: Int
    let title, summary, output: String
    let last: Bool
    var body: some View {
        VStack(spacing: 10) {
            StockTradeCard {
                HStack(alignment: .top, spacing: 12) {
                    Text("\(number)").font(.subheadline.weight(.semibold)).frame(width: 30, height: 30)
                        .foregroundStyle(StockTradeAppearance.selectedText)
                        .background(StockTradeAppearance.tint, in: Circle()).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(number). " + title).font(.headline)
                        Text(summary).font(.subheadline).foregroundStyle(.secondary)
                        Divider()
                        Text("产出 · " + output).font(.footnote)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !last { Image(systemName: "arrow.down").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true) }
        }
    }
}

private enum StockTradeGuideContent {
    struct Item { let title, detail, output: String }
    static let workflow: [Item] = [
        .init(title: "抓取行情", detail: "检查本地数据，制定增量计划，再从 Tushare 获取前复权日线。已有历史会合并更新；限流时等待并重试。", output: "本地行情文件与数据库"),
        .init(title: "策略初选", detail: "准备历史指标和流动性池，按后台启用的策略寻找候选，合并同一股票的结果。指定选股日期时，初选数据截止到该日。", output: "候选名单、策略来源与初选证据"),
        .init(title: "逐票复评", detail: "对每个候选执行资格过滤、四维评分、排序与风险检查，形成入选依据、排除原因和分层名单。", output: "单股复评与本轮推荐汇总"),
        .init(title: "校验并发布", detail: "检查候选、逐票复评和行情是否完整一致，通过后生成不可变快照，并更新已发布记录。", output: "可供客户端读取的完整结果")
    ]
    static let pools: [Item] = [
        .init(title: "初选候选", detail: "通过某个初选策略的股票，不代表已经通过复评与风险门槛。", output: ""),
        .init(title: "正式推荐", detail: "通过复评结论、规则评分、排序分、市场环境和风险门槛后，按排序取前 N 只。参考配置最多 3 只。", output: ""),
        .init(title: "达到分数门槛", detail: "实际实现记录的是通过全部推荐门槛的股票，可能多于最终 Top N，不是只检查规则评分这一项。", output: ""),
        .init(title: "近门槛观察", detail: "未进入正式推荐、复评结论为通过，且接近规则评分和排序门槛的股票；仍可能带有其他排除原因。", output: ""),
        .init(title: "强势观察", detail: "未进入正式推荐，但满足观察所需的评分、排序、市场及较低风险门槛。", output: ""),
        .init(title: "进取观察", detail: "未进入正式推荐和强势观察，符合边界评分区间或特定 B1 形态例外。它有独立条件，不是放宽全部风控。", output: ""),
        .init(title: "排除详情", detail: "没有进入最终推荐的股票及其门槛、风险等说明；未被选中也可能只是排名未进入 Top N。", output: "")
    ]
    struct Term: Identifiable {
        let category, title, english, detail: String
        var id: String { english }
    }
    static let categories = ["行情与指标", "策略与评分", "任务与结果"]
    static let terms: [Term] = [
        .init(category: categories[0], title: "日线与周线", english: "Daily / Weekly K-line", detail: "日线汇总一个交易日的开、高、低、收和成交量；周线汇总一周。尚未结束的周期会单独标记，不能当作已完成周期。"),
        .init(category: categories[0], title: "前复权", english: "QFQ", detail: "按除权除息等因素调整历史价格，便于比较跨时期趋势。图中历史价格可能不同于当时实际成交价。Cerno 抓取日线使用前复权。"),
        .init(category: categories[0], title: "均线与多头排列", english: "MA / Bullish alignment", detail: "MA 是一段周期收盘价的平均值。短周期均线在中、长周期均线上方称为多头排列，用于描述趋势关系，不代表未来一定上涨。"),
        .init(category: categories[0], title: "知行短期线与多空线", english: "ZXDQ / ZXDKX", detail: "本实现的短期线采用 10 周期双重指数平均；多空线采用 14、28、57、114 周期收盘价均线的平均。B1、B2 检查价格和短期线是否在多空线上方。"),
        .init(category: categories[0], title: "KDJ 与 J 值", english: "KDJ / J", detail: "KDJ 描述价格在近期区间的位置和动量，J 由 K、D 延伸计算，可低于 0 或高于 100。低 J 是初选条件之一，不能单独判断入选。"),
        .init(category: categories[0], title: "成交量、成交额与换手率", english: "Volume / Amount / Turnover rate", detail: "成交量是交易数量，成交额是金额，换手率是成交数量相对流通股份的比例。页面日线量以手显示，1 手为 100 股；这三个指标不能混用。"),
        .init(category: categories[0], title: "流动性池", english: "Liquidity pool / turnover_n", detail: "按滚动成交额指标筛出的策略运行范围，目的是优先分析有交易活跃度的股票。本实现以开收盘均价乘成交量近似每日成交额，再按窗口累计。"),
        .init(category: categories[0], title: "行业强度百分位", english: "industry_rank_pct", detail: "按行业强度在各行业间计算的相对百分位，数值越高越强。0.8 约为前 20%，0.5 约为前一半；不是股票在所属行业内的排名，也不是收益率。"),
        .init(category: categories[1], title: "B1、B2 与 Brick", english: "b1 / b2_confirm / brick", detail: "B1 找趋势中动量回落的候选；B2 找此前 B1 后出现的量价确认；Brick 使用砖型图柱体形态。是否执行由后台配置决定，策略条件见选股策略页。"),
        .init(category: categories[1], title: "规则评分", english: "total_score", detail: "将趋势、位置、量价、前期异动四维评分加权汇总，通常为 1～5 分。用于筛选门槛；4.6 分不代表 46% 或 92% 的胜率。"),
        .init(category: categories[1], title: "排序分", english: "rank_score", detail: "用于候选之间排序的 0～100 分指标，综合多个因子并扣除风险分。它与规则评分不同，80 分不表示有 80% 上涨概率。"),
        .init(category: categories[1], title: "风险分与一票否决", english: "risk_score / hard_veto", detail: "风险分累计规则识别的风险惩罚，越低表示该模型记录的风险越少。一票否决则直接阻止进入对应名单，高分也不能抵消；两者都不是损失概率。"),
        .init(category: categories[1], title: "市场环境评分", english: "market_regime_score", detail: "反映市场整体走势与宽度的规则指标，用于市场门槛或防御条件。0.45 是评分阈值，不代表 45% 胜率；它与行业百分位也不是同一项。"),
        .init(category: categories[1], title: "复评结论", english: "PASS / WATCH / FAIL", detail: "分别表示代码评分卡判定的通过、观察和未通过。PASS 之后仍要检查正式推荐门槛、风控和最终排序，并不自动成为正式推荐。"),
        .init(category: categories[1], title: "阈值、Top N 与形态例外", english: "Threshold / top_n / pattern exception", detail: "阈值是某项规则的边界；Top N 是通过条件后最多保留的数量。形态例外是满足额外证据时走的独立规则分支，不能只看某一个较低阈值。"),
        .init(category: categories[2], title: "完整任务与分步操作", english: "Full workflow / Stage", detail: "完整任务串联行情、初选、复评和发布。分步操作只做选定的一步；刷新页面只读数据，不会启动任何一步。"),
        .init(category: categories[2], title: "快照、数据日期与发布时间", english: "Snapshot / dataAsOf / publishedAt", detail: "快照是一份发布后固定的结果。数据日期是选股所依据的日期；发布时间是后台完成发布的时间，二者可能不同。查看历史快照不会重新计算。"),
        .init(category: categories[2], title: "排队、执行与等待", english: "queued / running", detail: "排队表示任务已接收；执行中可能正在处理，也可能等待数据锁、行情响应或限流冷却。应结合最近进展和日志判断，进程存活本身不代表处理数量在增加。"),
        .init(category: categories[2], title: "关注、监控与纸面持仓", english: "Favorite / Monitor / Paper position", detail: "关注是按账号与连接保存的本机收藏；后台监控记录规则状态和事件。纸面持仓是模拟状态，不是券商实际持仓，也不代表已经发出交易委托。")
    ]
}

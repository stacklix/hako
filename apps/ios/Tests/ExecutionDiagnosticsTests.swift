import Foundation

@MainActor private final class Events {
    var values: [HakoExecutionEvent] = []
    func append(_ event: HakoExecutionEvent) { values.append(event) }
}

@main struct ExecutionDiagnosticsTests {
    @MainActor static func main() async throws {
        checkFullLogExport()
        try await checkGroups()
        let outer = Events(), inner = Events()
        try await HakoExecutionDiagnostics.context.withValue({ outer.append($0) }) {
            let result = HakoExecutionDiagnostics.measure("读取设备身份记录") { 42 }
            precondition(result == 42)
            let value = try await HakoExecutionDiagnostics.measure("读取投资账本") {
                try await Task.sleep(for: .milliseconds(1))
                return "loaded"
            }
            precondition(value == "loaded")
            HakoExecutionDiagnostics.context.withValue({ inner.append($0) }) {
                HakoExecutionDiagnostics.record("独立任务")
            }
            do {
                try HakoExecutionDiagnostics.measure("读取服务端登录会话") {
                    throw NSError(domain: NSOSStatusErrorDomain, code: -25308,
                                  userInfo: [NSLocalizedDescriptionKey: "读取失败 Authorization: Bearer fake-token-123"])
                }
                preconditionFailure("Error was swallowed")
            } catch let error as NSError { precondition(error.code == -25308) }
            do {
                try await HakoExecutionDiagnostics.measure("取消操作") {
                    await Task.yield()
                    throw CancellationError()
                }
                preconditionFailure("Cancellation was swallowed")
            } catch is CancellationError {}
        }
        precondition(inner.values.count == 1 && inner.values[0].stage == "独立任务")
        precondition(outer.values.count == 8 && !outer.values.contains { $0.stage == "独立任务" })
        let failure = outer.values.first { $0.state == .failed }!
        precondition(failure.stage == "读取服务端登录会话")
        precondition(failure.detail.contains("-25308") && failure.detail.contains("errSecInteractionNotAllowed"))
        precondition(!failure.detail.contains("fake-token-123"), "Token leaked into diagnostics")
        precondition(outer.values.last?.state == .cancelled)
        let rows = HakoExecutionLogRow.merging(outer.values)
        precondition(rows.count == 4 && rows.allSatisfy { $0.startedAt != nil && $0.finishedAt != nil })
        precondition(rows.map(\.id) == stride(from: 0, to: 8, by: 2).map { outer.values[$0].id })
        precondition(rows.last?.state == .cancelled)
        let base = Date(timeIntervalSince1970: 1_000)
        let first = UUID(), second = UUID()
        let concurrent = HakoExecutionLogRow.merging([
            HakoExecutionEvent(id: first, time: base, stage: "同名请求", state: .started, detail: ""),
            HakoExecutionEvent(id: second, time: base.addingTimeInterval(1), stage: "同名请求", state: .started, detail: ""),
            HakoExecutionEvent(id: first, time: base.addingTimeInterval(2), stage: "同名请求", state: .succeeded, detail: "first"),
            HakoExecutionEvent(id: second, time: base.addingTimeInterval(4), stage: "同名请求", state: .failed, detail: "second")
        ])
        precondition(concurrent.count == 2 && concurrent[0].detail == "first" && concurrent[1].detail == "second")
        precondition(concurrent[0].elapsed(at: base) == "2.00 秒" && concurrent[1].elapsed(at: base) == "3.00 秒")
        let unpaired = HakoExecutionLogRow.merging([
            HakoExecutionEvent(time: base, stage: "开始记录已移出保留范围", state: .succeeded, detail: ""),
            HakoExecutionEvent(time: base, stage: "进行中", state: .started, detail: ""),
            HakoExecutionEvent(time: base, stage: "信息", state: .info, detail: "环境")
        ])
        precondition(unpaired[0].startedAt == nil && unpaired[0].elapsed(at: base) == "—")
        precondition(unpaired[1].finishedAt == nil && unpaired[1].elapsed(at: base.addingTimeInterval(0.005)) == "5 毫秒")
        precondition(unpaired[1].elapsed(at: base.addingTimeInterval(-1)) == "0 毫秒")
        precondition(unpaired[2].elapsed(at: base) == "0 毫秒")
        try checkSavedStageMerging()
        let summarized = Events()
        HakoExecutionDiagnostics.context.withValue({ summarized.append($0) }) {
            _ = HakoExecutionDiagnostics.measure("读取业务记录", success: { "已读取 \($0) 条记录。 Authorization: Bearer summary-secret" }) { 12 }
        }
        let summary = HakoExecutionLogRow.merging(summarized.values).first!
        precondition(summary.detail.contains("12 条记录") && !summary.detail.contains("summary-secret"))
        precondition(!summary.isDiagnostic)
        let technical = HakoExecutionLogRow.merging([
            HakoExecutionEvent(stage: "读取设备身份记录", state: .info, detail: ""),
            HakoExecutionEvent(stage: "发送请求 GET /api/v1/investment/book", state: .info, detail: ""),
            HakoExecutionEvent(stage: "读取 Binance 资产", state: .info, detail: "")
        ])
        precondition(technical.map(\.isDiagnostic) == [true, true, false], "Infrastructure hides business steps")
        precondition(!HTTPTransport.isTaskCancellation(URLError(.cancelled), taskCancelled: false), "Network cancellation was misreported as caller cancellation")
        precondition(HTTPTransport.isTaskCancellation(URLError(.cancelled), taskCancelled: true))
        precondition(HTTPTransport.isTaskCancellation(CancellationError(), taskCancelled: false))
        precondition(!HTTPTransport.isTaskCancellation(URLError(.timedOut), taskCancelled: false))
        let reason = HakoExecutionCancellation()
        reason.record("系统结束后台执行：超过允许的执行时间。")
        HakoExecutionDiagnostics.cancellation.withValue(reason) {
            precondition(HakoExecutionDiagnostics.failure(CancellationError()).contains("系统结束后台执行"))
        }
        precondition(HakoExecutionDiagnostics.cancellation.get() == nil)
        let cancelledTransport = Events()
        let cancelledTask = Task { @MainActor in
            try await HakoExecutionDiagnostics.context.withValue({ cancelledTransport.append($0) }) {
                try await HakoExecutionDiagnostics.measure("随父任务取消的网络请求") {
                    await Task.yield()
                    withUnsafeCurrentTask { $0?.cancel() }
                    throw URLError(.cancelled)
                }
            }
        }
        do { _ = try await cancelledTask.value; preconditionFailure("Cancelled transport completed") }
        catch let error as URLError { precondition(error.code == .cancelled) }
        precondition(cancelledTransport.values.last?.state == .cancelled, "Cancelled request was still displayed as a network failure")
        let count = outer.values.count
        HakoExecutionDiagnostics.record("无接收器")
        precondition(outer.values.count == count && HakoExecutionDiagnostics.sink == nil)
        let data = try JSONEncoder().encode(outer.values)
        let restored = try JSONDecoder().decode([HakoExecutionEvent].self, from: data)
        precondition(restored.map(\.id) == outer.values.map(\.id))
        print("PASS: correlated and saved legacy stages, concurrent names, retry boundaries, pending/truncated timing, cancellation sources, transport errors, redaction and persistence")
    }

    private static func checkFullLogExport() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let id = UUID(), group = UUID()
        let stage = "[组 · \(group.uuidString)] [并行 · 标的行情] 准备标的行情"
        let longDetail = "完整详情开始\n" + String(repeating: "数据", count: 3000) + "\n完整详情结束"
        let events = [
            HakoExecutionEvent(id: id, time: base, stage: stage, state: .started, detail: "开始"),
            HakoExecutionEvent(time: base.addingTimeInterval(0.125), stage: "行情缓存缺口 · BTC", state: .info,
                               detail: "缺口 0 个；token=do-not-copy"),
            HakoExecutionEvent(id: id, time: base.addingTimeInterval(0.25), stage: stage, state: .succeeded, detail: longDetail)
        ]
        let export = HakoExecutionLogExport.text(title: "更新投资账本", metadata: ["执行 ID：example"], events: events,
            startedAt: base, finishedAt: base.addingTimeInterval(0.25), now: base.addingTimeInterval(1), capacity: 3)
        precondition(export.contains(".125Z") && export.contains("相对开始：0.125 秒"))
        precondition(export.contains("250 毫秒") && export.contains("分支：标的行情"))
        precondition(export.contains("本次结束：") && export.contains(".250Z"))
        precondition(export.contains(group.uuidString) && export.components(separatedBy: id.uuidString).count >= 3)
        precondition(export.contains("#1 ") && export.contains("#2 ") && export.contains("#3 "))
        precondition(export.contains("完整详情开始") && export.contains("完整详情结束"), "Export must not add another truncation limit")
        precondition(export.contains("[诊断] 行情缓存缺口 · BTC") && export.contains("已达到保留上限"))
        precondition(!export.contains("do-not-copy") && export.contains("[已隐藏]"))
    }

    @MainActor private static func checkGroups() async throws {
        let events = Events()
        await HakoExecutionDiagnostics.context.withValue({ events.append($0) }) {
            let result = await HakoExecutionDiagnostics.measureGroup("采集计划", branches: 2, detail: "最多同时运行 2 个", resultState: { $0 ? .succeeded : .failed }) {
                await HakoExecutionDiagnostics.parallel.withValue("A") {
                    await HakoExecutionDiagnostics.measure("读取 A") {
                        await Task.yield()
                        HakoExecutionDiagnostics.record("资产接口 GET api.test/balance")
                    }
                }
                let partial = HakoExecutionLogItem.grouping(HakoExecutionLogRow.merging(events.values)).first!
                precondition(partial.row.state == .started && partial.row.plannedBranches == 2 && partial.completedBranches == 1)
                precondition(partial.children.count == 1 && !partial.children[0].row.isAssetRequest)
                do {
                    try HakoExecutionDiagnostics.parallel.withValue("B") {
                        try HakoExecutionDiagnostics.measure("读取 B") { throw NSError(domain:"test", code:1) }
                    }
                } catch {}
                return false
            }
            precondition(!result)
            // Same-named groups and branches from a retry have distinct ownership.
            _ = await HakoExecutionDiagnostics.measureGroup("采集计划", branches: 1, detail: "最多同时运行 1 个") {
                HakoExecutionDiagnostics.measure("读取 A") { 42 }
            }
        }
        let rows = HakoExecutionLogRow.merging(events.values)
        let items = HakoExecutionLogItem.grouping(rows)
        precondition(items.count == 2 && items[0].row.state == .failed && items[1].row.state == .succeeded)
        precondition(items[0].completedBranches == 2 && items[1].completedBranches == 1)
        precondition(items[0].children.map { $0.row.stageTitle } == ["读取 A", "读取 B"])
        precondition(items[1].children.count == 1 && items[1].children[0].row.parentGroupID == items[1].id)
        precondition(items[0].children.allSatisfy { $0.row.parentGroupID == items[0].id })
        let request = rows.first { $0.isAssetRequest }!
        precondition(request.isDiagnostic && request.parallelBranch == "A" && request.parentGroupID == items[0].id)
        precondition(events.values.first { $0.stage.contains("资产接口") }?.stageTitle == "资产接口 GET api.test/balance")
        precondition(HakoExecutionDiagnostics.group.get() == nil && HakoExecutionDiagnostics.parallel.get() == nil)

        let cancelled = Events()
        do {
            try await HakoExecutionDiagnostics.context.withValue({ cancelled.append($0) }) {
                try await HakoExecutionDiagnostics.measureGroup("采集计划", branches: 2, detail: "最多同时运行 2 个") {
                    try await HakoExecutionDiagnostics.parallel.withValue("A") {
                        try await HakoExecutionDiagnostics.measure("读取 A") {
                            await Task.yield()
                            throw CancellationError()
                        }
                    }
                }
            }
            preconditionFailure("Group swallowed cancellation")
        } catch is CancellationError {}
        let cancelledGroup = HakoExecutionLogItem.grouping(HakoExecutionLogRow.merging(cancelled.values)).first!
        precondition(cancelledGroup.row.state == .cancelled && cancelledGroup.row.plannedBranches == 2)
        precondition(cancelledGroup.completedBranches == 1 && cancelledGroup.children[0].row.state == .cancelled)

        let base = Date(timeIntervalSince1970:1000), id = UUID()
        let timeline = HakoExecutionLogRow.merging([
            HakoExecutionEvent(id:id,time:base,stage:"[分组 · 2] 采集计划",state:.started,detail:""),
            HakoExecutionEvent(time:base,stage:"[组 · \(id.uuidString)] [并行 · A] A",state:.started,detail:""),
            HakoExecutionEvent(id:id,time:base.addingTimeInterval(7),stage:"[分组 · 2] 采集计划",state:.succeeded,detail:"")
        ])
        let group = HakoExecutionLogItem.grouping(timeline).first!
        precondition(group.row.elapsed(at:base.addingTimeInterval(99)) == "7.00 秒", "Plan time was derived from branch durations")
        precondition(group.children.count == 1 && group.completedBranches == 0)
        precondition(HakoExecutionLogItem.grouping(Array(timeline.dropFirst())).count == 1, "Truncated parent discarded branch logs")
    }

    private static func checkSavedStageMerging() throws {
        let base = Date(timeIntervalSince1970: 1_000)
        func event(_ stage: String, _ state: HakoExecutionEvent.State, _ offset: Double, _ detail: String = "") -> HakoExecutionEvent {
            HakoExecutionEvent(time: base.addingTimeInterval(offset), stage: stage, state: state, detail: detail)
        }
        // Reproduce saved pre-0.8.94 records: every event has a different UUID.
        let original = [
            event("读取服务端投资账本", .started, 0),
            event("恢复服务端登录会话", .started, 0.01),
            event("读取设备身份记录", .started, 0.02),
            event("读取设备身份记录", .succeeded, 0.021, "耗时：1 毫秒"),
            event("恢复服务端登录会话", .succeeded, 0.03, "耗时：20 毫秒"),
            event("读取服务端投资账本", .cancelled, 15.5, "耗时：15500 毫秒\n错误域：Swift.CancellationError"),
            event("读取设备身份记录", .started, 16),
            event("读取设备身份记录", .failed, 16.01, "耗时：10 毫秒\n读取失败")
        ]
        let saved = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode([HakoExecutionEvent].self, from: saved)
        let rows = HakoExecutionLogRow.merging(restored)
        precondition(rows.count == 4, "Saved stage starts and finishes are still separate rows")
        precondition(rows.map(\.id) == [original[0].id, original[1].id, original[2].id, original[6].id])
        precondition(rows[2].stage == "读取设备身份记录" && rows[2].state == .succeeded)
        precondition(rows[2].startedAt == original[2].time && rows[2].finishedAt == original[3].time)
        precondition(rows[2].elapsed(at: base) == "1 毫秒" && rows[2].detail.isEmpty)
        precondition(rows[0].state == .cancelled && rows[0].detail == "错误域：Swift.CancellationError")
        precondition(rows[3].state == .failed && rows[3].detail == "读取失败")
        precondition(restored.map(\.id) == original.map(\.id) && restored.map(\.detail) == original.map(\.detail))
        precondition(restored.map(\.state) == original.map(\.state) && restored.map(\.time) == original.map(\.time))

        let correlated = UUID()
        let mixed = HakoExecutionLogRow.merging([
            event("读取身份", .started, 0),
            HakoExecutionEvent(id: correlated, time: base, stage: "读取身份", state: .started, detail: ""),
            event("读取身份", .succeeded, 1),
            HakoExecutionEvent(id: correlated, time: base.addingTimeInterval(2), stage: "读取身份", state: .failed, detail: "new")
        ])
        precondition(mixed.count == 2 && mixed[0].state == .succeeded && mixed[1].state == .failed)
        precondition(mixed[1].detail == "new", "Name matching stole a correlated finish")

        let ambiguous = HakoExecutionLogRow.merging([
            event("并发同名旧阶段", .started, 0), event("并发同名旧阶段", .started, 1),
            event("并发同名旧阶段", .succeeded, 2), event("并发同名旧阶段", .failed, 3)
        ])
        precondition(ambiguous.count == 4, "Ambiguous legacy phases were paired without evidence")
        let retried = HakoExecutionLogRow.merging([
            event("未完成阶段", .started, 0), event("子任务结束", .cancelled, 1),
            event("重试子任务", .started, 2), event("未完成阶段", .succeeded, 3)
        ])
        precondition(retried.count == 4, "A retry finish was attached to an earlier attempt")
        let infoAndTruncated = HakoExecutionLogRow.merging([
            event("相同名称", .succeeded, 0), event("相同名称", .started, 1),
            event("相同名称", .info, 2, "阶段内信息"), event("相同名称", .succeeded, 3)
        ])
        precondition(infoAndTruncated.count == 3 && infoAndTruncated[0].startedAt == nil)
        precondition(infoAndTruncated[1].finishedAt == base.addingTimeInterval(3))
        precondition(infoAndTruncated[2].detail == "阶段内信息")
    }
}

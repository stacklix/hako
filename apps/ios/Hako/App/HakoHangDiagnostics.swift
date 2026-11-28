import Foundation
import CryptoKit
import MetricKit
import UIKit

// The local detector persists responsiveness loss before the main queue recovers.
// Only MetricKit reports provide system-captured stacks, never this worker's stack.
final class HakoHangDiagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = HakoHangDiagnostics()
    private let queue = DispatchQueue(label: "me.stackli.hako.hang-diagnostics", qos: .utility)
    private let monitorQueue = DispatchQueue(label: "me.stackli.hako.main-responsiveness", qos: .userInitiated)
    private var monitor = HakoHangMonitorState()
    private var timer: DispatchSourceTimer?
    @MainActor private var observers: [NSObjectProtocol] = []
    @MainActor private var started = false

    @MainActor func start() {
        guard !started else { return }
        started = true
        HakoDiagnosticStore.shared.breadcrumb("诊断监测已启动", detail: "本次进程启动；主线程响应阈值 2 秒")
        MXMetricManager.shared.add(self)
        queue.async { self.didReceive(MXMetricManager.shared.pastDiagnosticPayloads) }
        observers = [
            NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.setActive(false) },
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.setActive(true) }
        ]
        monitorQueue.async { [self] in
            let timer = DispatchSource.makeTimerSource(queue: self.monitorQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer; timer.resume()
        }
        setActive(UIApplication.shared.applicationState == .active)
    }

    func setActive(_ active: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        monitorQueue.async {
            guard self.monitor.active != active else { return }
            if let event = self.monitor.setActive(active, now: now) { self.save(event) }
            HakoDiagnosticStore.shared.breadcrumb(active ? "应用进入活跃前台" : "应用离开活跃前台")
        }
    }

    private func tick() {
        let result = monitor.tick(now: ProcessInfo.processInfo.systemUptime)
        if let event = result.event { save(event) }
        guard let ping = result.ping else { return }
        DispatchQueue.main.async { [weak self] in
            let now = ProcessInfo.processInfo.systemUptime
            self?.acknowledge(ping, at: now)
        }
    }

    private func acknowledge(_ ping: UInt64, at now: TimeInterval) {
        monitorQueue.async {
            if let event = self.monitor.acknowledge(ping, now: now) { self.save(event) }
        }
    }

    private func save(_ event: HakoHangMonitorState.Event) {
        let status: String
        switch event.phase {
        case .blocked: status = "检测时主线程仍未响应，已在后台保存；尚不能确认是否恢复或退出。"
        case .recovered: status = "主线程已恢复响应。"
        case .inactive: status = "应用离开活跃前台，停止此次检测；不将后台或锁屏时间计为卡顿。"
        }
        HakoDiagnosticStore.shared.record(.localHang,
            detail: "持续时间：\(String(format: "%.2f", event.duration)) 秒\n\(status)\n来源：本机主队列响应检测，阈值 2 秒。此记录不包含主线程调用栈，也不等同于崩溃报告。",
            id: event.id, time: Date().addingTimeInterval(-event.duration))
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        queue.async {
            for payload in payloads {
                for hang in payload.hangDiagnostics ?? [] {
                    let data = hang.jsonRepresentation()
                    let seconds = hang.hangDuration.converted(to: .seconds).value
                    let report = String(decoding: data, as: UTF8.self)
                    HakoDiagnosticStore.shared.record(.systemHang,
                        detail: "持续时间：\(seconds) 秒\n报告区间（不是精确发生时间）：\(payload.timeStampBegin) — \(payload.timeStampEnd)\n\(report)",
                        fingerprint: "hang:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
                }
                for crash in payload.crashDiagnostics ?? [] {
                    let data = crash.jsonRepresentation()
                    HakoDiagnosticStore.shared.record(.crash,
                        detail: "终止原因：\(crash.terminationReason ?? "系统未提供")\n报告区间（不是精确发生时间）：\(payload.timeStampBegin) — \(payload.timeStampEnd)\n" + String(decoding: data, as: UTF8.self),
                        fingerprint: "crash:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
                }
            }
        }
    }
}

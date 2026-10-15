import Foundation
import SwiftUI
import FamilyControls
import DeviceActivity
import ManagedSettings

@MainActor enum ScreenTime {
    static func installedApplications() async -> [String: Application] {
        guard AuthorizationCenter.shared.authorizationStatus == .approvedWithDataAccess,
              let applications = try? await FamilyActivityData.shared.installedApplications else { return [:] }
        return applications.reduce(into: [:]) { result, application in
            if let id = application.bundleIdentifier { result[id] = application }
        }
    }
    static func authorizeIfNeeded() async throws {
        guard AuthorizationCenter.shared.authorizationStatus != .approvedWithDataAccess else { return }
        try await authorize()
    }
    static func authorize() async throws {
        try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        try checkAuthorization()
    }
    static func checkAuthorization() throws {
        switch AuthorizationCenter.shared.authorizationStatus {
        case .approvedWithDataAccess:
            return
        case .notDetermined:
            throw HakoError(message: "尚未授权（notDetermined）。请打开 Hako 的使用时间模块，点击「补齐最近7天并同步」完成系统授权，再运行快捷指令。")
        case .denied:
            throw HakoError(message: "系统授权已被拒绝（denied）。请在 Hako 使用时间模块重新点击「补齐最近7天并同步」，并允许系统请求；如无法重新授权，请检查 iPhone 设置中的屏幕使用时间权限。")
        case .approved:
            throw HakoError(message: "仅获得普通屏幕时间权限（approved），尚未获得数据导出权限（approvedWithDataAccess）。请确认开发描述文件支持 App and Website Usage。即使应用已安装且同意普通授权，也不代表可以导出。若签名权限齐全，需继续核实 Apple 的开发测试及地区条件。")
        @unknown default:
            throw HakoError(message: "系统返回未知授权状态：\(AuthorizationCenter.shared.authorizationStatus.rawValue)。请检查 iOS 版本与签名授权。")
        }
    }
    static func collect(_ day: UsageDay) async throws -> DailyUsage {
        try checkAuthorization()
        let installed = await installedApplications()
        let filter = DeviceActivityFilter(segment: .daily(during: day.interval), users: .all, devices: .init([.iPhone]))
        var total = 0.0
        var apps: [String: AppUsage] = [:]
        var segments = 0
        for try await data in DeviceActivityData.activityData(filteredBy: filter, using: .live) {
            for await segment in data.activitySegments {
                segments += 1
                total += segment.totalActivityDuration
                for await category in segment.categories {
                    for await activity in category.applications {
                        guard let id = activity.application.bundleIdentifier else {
                            throw HakoError(message: "系统未返回 App 标识，无法可靠生成排行榜。")
                        }
                        let name = [activity.application.localizedDisplayName, installed[id]?.localizedDisplayName]
                            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .first { !$0.isEmpty && $0 != id } ?? id
                        let token = installed[id]?.token ?? activity.application.token
                        let tokenData = token.flatMap { try? JSONEncoder().encode($0) }
                        var item = apps[id] ?? AppUsage(bundleID: id, name: name, seconds: 0, applicationTokenData: tokenData)
                        if item.applicationTokenData == nil { item.applicationTokenData = tokenData }
                        item.seconds += activity.totalActivityDuration
                        apps[id] = item
                    }
                }
            }
        }
        guard segments > 0 else { throw HakoError(message: "系统尚未提供该日数据，请稍后重试。没有写入零时长记录。") }
        let top = apps.values.sorted { $0.seconds == $1.seconds ? $0.bundleID < $1.bundleID : $0.seconds > $1.seconds }.prefix(5)
        return try DailyUsage(day: day.key, timeZone: day.timeZone, totalSeconds: total, apps: Array(top))
    }
}

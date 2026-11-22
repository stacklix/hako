import SwiftUI

enum RouterStyle {
    static let background = color(0xf4f4f6, 0x101012)
    static let panel = color(0xffffff, 0x1c1c1f)
    static let text = color(0x161619, 0xf5f5f7)
    static let muted = color(0x77777e, 0xa0a0a7)
    static let fill = color(0xececef, 0x29292d)
    static let line = color(0xe8e8eb, 0x303034)
    static let green = color(0x237b58, 0x83cdaa)
    private static func color(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { trait in
            let value = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: Double(value >> 16 & 255) / 255, green: Double(value >> 8 & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
        })
    }
}

struct RouterPanel<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View { VStack(spacing: 0) { content }.background(RouterStyle.panel, in: RoundedRectangle(cornerRadius: 18)) }
}
struct RouterSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View { VStack(alignment: .leading, spacing: 12) { Text(title).font(.headline); content } }
}
struct RouterMenuRow: View {
    let title: String
    let symbol: String
    var subtitle = ""
    var value = ""
    var separator = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.subheadline).frame(width: 32, height: 32)
                    .background(RouterStyle.fill, in: RoundedRectangle(cornerRadius: 9)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.medium))
                    if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(RouterStyle.muted) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if !value.isEmpty { Text(value).font(.caption).foregroundStyle(RouterStyle.muted).multilineTextAlignment(.trailing) }
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(RouterStyle.muted).accessibilityHidden(true)
            }.padding(15).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .overlay(alignment: .bottom) { if separator { Divider().padding(.horizontal, 15) } }
    }
}
struct RouterFact: View {
    let title: String
    let value: String
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value.isEmpty ? "未提供" : value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.subheadline).frame(maxWidth: .infinity)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }
}
struct RouterBadge: View {
    let text: String
    var good = false
    var tint: Color? = nil
    private var color: Color { tint ?? (good ? RouterStyle.green : RouterStyle.muted) }
    var body: some View {
        Text(text).font(.caption2).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
    }
}

enum RouterPage: String, CaseIterable, Identifiable {
    case overview = "概览", devices = "设备", network = "网络", tools = "工具"
    var id: Self { self }
    var symbol: String {
        switch self { case .overview: "square.grid.2x2"; case .devices: "desktopcomputer"; case .network: "network"; case .tools: "slider.horizontal.3" }
    }
    var resources: [RouterResource] {
        switch self {
        case .overview: [.hardware, .capabilities, .wan, .ports, .mesh]
        case .devices: []
        case .network: [.wireless, .guest, .dhcp, .ports, .mesh]
        case .tools: [.upnp]
        }
    }
}
enum RouterScreen: Identifiable {
    case settings, device(String), bindings, resource(RouterResource)
    var id: String {
        switch self {
        case .settings: "settings"
        case .bindings: "bindings"
        case .device(let mac): "device:" + mac
        case .resource(let resource): "resource:" + resource.rawValue
        }
    }
}

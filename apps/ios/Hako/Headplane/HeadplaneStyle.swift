import SwiftUI

enum HeadplaneStyle {
    static let background = color(0xffffff, 0x17181a)
    static let text = color(0x18191b, 0xf1f2f3)
    static let muted = color(0x797c83, 0xa0a3aa)
    static let fill = color(0xf5f6f7, 0x232529)
    static let line = color(0xeceeF0, 0x303237)
    static let green = color(0x237b54, 0x71cda2)
    static let orange = color(0xa66a16, 0xe4b46d)
    static let red = color(0xc23d42, 0xff8b8f)
    private static func color(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { trait in
            let v = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255, alpha: 1)
        })
    }
}

extension View {
    func headplaneCard() -> some View {
        padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(HeadplaneStyle.background, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(HeadplaneStyle.line, lineWidth: 1))
    }
}

struct HeadplaneButtonStyle: ButtonStyle {
    var primary = false
    var destructive = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.medium)).padding(.horizontal, 15).frame(minHeight: 44)
            .frame(maxWidth: .infinity)
            .foregroundStyle(destructive ? HeadplaneStyle.red : primary ? HeadplaneStyle.background : HeadplaneStyle.text)
            .background(primary ? HeadplaneStyle.text : HeadplaneStyle.fill, in: RoundedRectangle(cornerRadius: 10))
            .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
    }
}

struct HeadplaneBadge: View {
    let text: String
    var good = true
    var body: some View {
        Text(text).font(.caption2).foregroundStyle(good ? HeadplaneStyle.green : HeadplaneStyle.orange)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background((good ? HeadplaneStyle.green : HeadplaneStyle.orange).opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
    }
}

struct HeadplaneFact: View {
    let title: String
    let value: String
    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                Text(title).foregroundStyle(HeadplaneStyle.muted)
                Spacer(minLength: 10)
                Text(value.isEmpty ? "未提供" : value).multilineTextAlignment(.trailing).textSelection(.enabled)
            }.font(.subheadline)
            Rectangle().fill(HeadplaneStyle.line).frame(height: 0.5)
        }
    }
}

struct HeadplaneField<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.subheadline).foregroundStyle(HeadplaneStyle.muted)
            content().accessibilityLabel(title).padding(12)
                .background(HeadplaneStyle.fill, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct HeadplaneSheet<Content: View>: View {
    let title: String
    var busy = false
    var dirty = false
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss
    @State private var discard = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 17, content: content)
                    .padding(.horizontal, 24).padding(.vertical, 20)
            }
            .background(HeadplaneStyle.background)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { if dirty { discard = true } else { dismiss() } } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("关闭").disabled(busy)
                }
            }
            .confirmationDialog("放弃尚未保存的修改？", isPresented: $discard, titleVisibility: .visible) {
                Button("放弃修改", role: .destructive) { dismiss() }
                Button("继续编辑", role: .cancel) { }
            }
        }.tint(HeadplaneStyle.text).foregroundStyle(HeadplaneStyle.text)
            .presentationDragIndicator(.visible).interactiveDismissDisabled(busy || dirty)
    }
}

struct HeadplaneErrorText: View {
    let message: String?
    var body: some View {
        if let message { Text(message).font(.footnote).foregroundStyle(HeadplaneStyle.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
    }
}

import SwiftUI

/// Shared style for prominent form actions, matching the access-key creation button.
struct HakoActionButtonStyle: ButtonStyle {
    var primary = true
    var destructive = false
    @Environment(\.isEnabled) private var enabled

    private var text: Color { color(0x18191b, 0xf1f2f3) }
    private var background: Color { color(0xffffff, 0x17181a) }
    private var fill: Color { color(0xf5f6f7, 0x232529) }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.medium))
            .padding(.horizontal, 15).frame(minHeight: 44)
            .frame(maxWidth: .infinity)
            .foregroundStyle(destructive ? color(0xc23d42, 0xff8b8f) : primary ? background : text)
            .background(primary ? text : fill, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
    }

    private func color(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { trait in
            let value = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
        })
    }
}

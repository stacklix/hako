import SwiftUI

/// Shared style for prominent form actions, matching the access-key creation button.
struct HakoActionButtonStyle: ButtonStyle {
    var primary = true
    var destructive = false
    var outlined = false
    var backgroundColor: Color? = nil
    @Environment(\.isEnabled) private var enabled

    private static let text = HakoStyle.adaptive(0x18191b, 0xf1f2f3)
    private static let primaryText = HakoStyle.adaptive(0xffffff, 0x17181a)
    private static let secondaryFill = HakoStyle.adaptive(0xf5f6f7, 0x262629)
    private static let secondaryBorder = HakoStyle.adaptive(0xc4c6ce, 0x585860)
    private static let destructiveText = HakoStyle.adaptive(0xa52b38, 0xff9da8)
    private static let destructiveFill = HakoStyle.adaptive(0xfff0f1, 0x331d22)
    private static let destructiveBorder = HakoStyle.adaptive(0xefc5cb, 0x62323b)

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        return configuration.label.font(.subheadline.weight(.medium))
            .padding(.horizontal, 15).frame(minHeight: 44)
            .frame(maxWidth: .infinity)
            .foregroundStyle(destructive ? Self.destructiveText : primary ? Self.primaryText : Self.text)
            .background(backgroundColor ?? (destructive ? Self.destructiveFill : primary ? Self.text : Self.secondaryFill), in: shape)
            .overlay {
                if destructive {
                    shape.strokeBorder(Self.destructiveBorder, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(shape)
            .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
            .overlay {
                if outlined && !primary && !destructive {
                    shape.strokeBorder(Self.secondaryBorder.opacity(enabled ? 1 : 0.7), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
    }
}

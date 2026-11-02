import SwiftUI

/// Explicit outlines keep actions distinct without the heavy system tinted fill.
struct ArcaneActionButtonStyle: ButtonStyle {
    var destructive = false
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let color: Color = destructive ? .red : .primary
        configuration.label
            .font(.subheadline.weight(.medium))
            .imageScale(.small)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .foregroundStyle(prominent ? Color(uiColor: .systemBackground) : color)
            .background(prominent ? color : Color.clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(color.opacity(destructive ? 0.25 : 0.16), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
    }
}

struct ArcaneOperationBadge: View {
    let status: ArcaneOperationStatus
    var body: some View {
        HStack(spacing: 5) {
            if status.running { ProgressView().controlSize(.mini).tint(.orange) }
            Text(status.text)
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    func arcaneRowSeparators() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { dimensions in dimensions.width }
    }
}

import SwiftUI

private struct ArcaneActionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}

/// Color distinguishes actions from read-only content without adding visual weight.
struct ArcaneActionButtonStyle: ButtonStyle {
    var destructive = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let color: Color = isEnabled ? (destructive ? .red : .blue) : .secondary
        configuration.label
            .labelStyle(ArcaneActionLabelStyle())
            .font(.subheadline.weight(.medium))
            .imageScale(.small)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .foregroundStyle(color)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.5 : 1)
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

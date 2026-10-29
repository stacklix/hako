import SwiftUI

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

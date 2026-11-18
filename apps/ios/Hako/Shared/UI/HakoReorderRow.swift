import SwiftUI

extension View {
    // Native reorder handles are outside the content alignment guides.
    func hakoReorderRow(showsSeparator: Bool = true) -> some View {
        self.listRowSeparator(.hidden)
            .listRowBackground(
                Color(uiColor: .secondarySystemGroupedBackground)
                    .overlay(alignment: .bottom) {
                        if showsSeparator { Divider().padding(.horizontal, 16) }
                    }
            )
    }
}

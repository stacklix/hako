struct ConversationScrollFollowing {
    struct Layout: Equatable {
        let contentHeight: Double
        let viewportHeight: Double
        let nearBottom: Bool
        let needsBottomAlignment: Bool

        init(contentHeight: Double, viewportHeight: Double, visibleBottom: Double) {
            self.contentHeight = contentHeight
            self.viewportHeight = viewportHeight
            nearBottom = contentHeight - visibleBottom <= 80
            needsBottomAlignment = contentHeight - visibleBottom > 1
        }
    }

    private(set) var followsBottom = true
    private var manualScroll = false
    private var nearBottom = true
    private var layout: Layout?

    var shouldFollowUpdates: Bool { followsBottom && !manualScroll }

    mutating func observe(_ next: Layout) -> Bool {
        let resized = layout?.contentHeight != next.contentHeight || layout?.viewportHeight != next.viewportHeight
        layout = next
        observe(nearBottom: next.nearBottom)
        // Lazy rows, images and attributed text can finish measuring after the
        // message revision has already scrolled. Reapply the edge on real size
        // changes, not on offsets caused by scrolling itself.
        return resized && shouldFollowUpdates && next.viewportHeight > 0 && next.needsBottomAlignment
    }

    mutating func observe(nearBottom: Bool) {
        self.nearBottom = nearBottom
        // Content can grow before its scroll anchor is applied. Only a user's
        // scroll away from the bottom should turn off response following.
        if manualScroll || nearBottom { followsBottom = nearBottom }
    }

    mutating func interacting(_ active: Bool) {
        if active { manualScroll = true }
        else if manualScroll {
            followsBottom = nearBottom
            manualScroll = false
        }
    }
}

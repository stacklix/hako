struct ConversationScrollFollowing {
    struct Layout: Equatable {
        let contentHeight: Double
        let viewportHeight: Double
        let nearBottom: Bool
        let needsBottomAlignment: Bool
        let pastBottom: Bool

        init(contentHeight: Double, viewportHeight: Double, visibleBottom: Double) {
            self.contentHeight = contentHeight
            self.viewportHeight = viewportHeight
            nearBottom = contentHeight - visibleBottom <= 80
            needsBottomAlignment = abs(max(contentHeight, viewportHeight) - visibleBottom) > 1
            // Ignore ordinary short content and small elastic scroll bounces.
            pastBottom = visibleBottom - max(contentHeight, viewportHeight) > 80
        }
    }

    private(set) var followsBottom = true
    private var manualScroll = false
    private var nearBottom = true
    private var layout: Layout?
    private var pendingMessageID: String?

    var shouldFollowUpdates: Bool { followsBottom && !manualScroll }

    mutating func messageAppended(_ id: String) {
        followsBottom = true
        manualScroll = false
        pendingMessageID = id
    }

    mutating func presentationUpdated(containsMessage: (String) -> Bool) -> Bool {
        if let pendingMessageID {
            guard containsMessage(pendingMessageID) else { return false }
            self.pendingMessageID = nil
        }
        return shouldFollowUpdates
    }

    mutating func observe(_ next: Layout) -> Bool {
        let resized = layout?.contentHeight != next.contentHeight || layout?.viewportHeight != next.viewportHeight
        layout = next
        observe(nearBottom: next.nearBottom)
        // Lazy rows, images and attributed text can finish measuring after the
        // message revision has already scrolled. Reapply the edge on real size
        // changes, not on offsets caused by scrolling itself.
        return (resized || next.pastBottom) && pendingMessageID == nil && shouldFollowUpdates &&
            next.contentHeight > 0 && next.viewportHeight > 0 && next.needsBottomAlignment
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

struct ConversationScrollFollowing {
    struct Layout: Equatable {
        let contentHeight: Double
        let viewportHeight: Double
        let nearBottom: Bool
        let atBottom: Bool
        let needsBottomAlignment: Bool
        let pastBottom: Bool
        private let overscrollDistance: Double

        init(contentHeight: Double, viewportHeight: Double, visibleBottom: Double) {
            self.contentHeight = contentHeight
            self.viewportHeight = viewportHeight
            nearBottom = contentHeight - visibleBottom <= 80
            // The read-status threshold is deliberately generous. Resuming
            // automatic scrolling must require actually returning to the edge.
            atBottom = max(contentHeight, viewportHeight) - visibleBottom <= 8
            needsBottomAlignment = abs(max(contentHeight, viewportHeight) - visibleBottom) > 1
            // Ignore ordinary short content and small elastic scroll bounces.
            pastBottom = visibleBottom - max(contentHeight, viewportHeight) > 80
            overscrollDistance = max(0, visibleBottom - max(contentHeight, viewportHeight) - 80).rounded()
        }
    }

    private(set) var followsBottom = true
    private var manualScroll = false
    private var nearBottom = true
    private var layout: Layout?
    private var pendingMessageID: String?
    private var lastAlignment: Layout?

    var shouldFollowUpdates: Bool { followsBottom && !manualScroll }

    mutating func messageAppended(_ id: String) {
        followsBottom = true
        manualScroll = false
        pendingMessageID = id
        lastAlignment = nil
    }

    mutating func presentationUpdated(containsMessage: (String) -> Bool) -> Bool {
        let appended = pendingMessageID != nil
        if let pendingMessageID {
            guard containsMessage(pendingMessageID) else { return false }
            self.pendingMessageID = nil
        }
        return requestAlignment(allowAligned: appended)
    }

    mutating func observe(_ next: Layout) -> Bool {
        let resized = layout?.contentHeight != next.contentHeight || layout?.viewportHeight != next.viewportHeight
        layout = next
        observe(nearBottom: next.atBottom)
        if !next.needsBottomAlignment { lastAlignment = nil }
        // Lazy rows, images and attributed text can finish measuring after the
        // message revision has already scrolled. Reapply the edge on real size
        // changes, not on offsets caused by scrolling itself.
        guard (resized || next.pastBottom), pendingMessageID == nil,
              next.contentHeight > 0, next.viewportHeight > 0 else { return false }
        return requestAlignment()
    }

    private mutating func requestAlignment(allowAligned: Bool = false) -> Bool {
        guard shouldFollowUpdates else { return false }
        if let layout {
            guard allowAligned || layout.needsBottomAlignment else { return false }
            // Rendering, retry state and geometry can all report the same
            // layout. One correction is enough until its measurements change.
            guard lastAlignment != layout else { return false }
            lastAlignment = layout
        }
        return true
    }

    mutating func observe(nearBottom: Bool) {
        self.nearBottom = nearBottom
        // Content can grow before its scroll anchor is applied. Only a user's
        // scroll away from the bottom should turn off response following.
        if manualScroll || nearBottom { followsBottom = nearBottom }
    }

    mutating func interacting(_ active: Bool) {
        if active { manualScroll = true; lastAlignment = nil }
        else if manualScroll {
            followsBottom = nearBottom
            manualScroll = false
        }
    }
}

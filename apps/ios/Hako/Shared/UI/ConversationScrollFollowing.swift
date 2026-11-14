struct ConversationScrollFollowing {
    private(set) var followsBottom = true
    private var manualScroll = false
    private var nearBottom = true

    var shouldFollowUpdates: Bool { followsBottom && !manualScroll }

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

import Foundation

// A brick is two or more sessions done back to back as one outing: a run off the bike, or
// the legs of a race. Its sessions share a `brickID` and sit on one day of one plan. A
// session whose brick-mates have moved to another day is simply not in a brick any more,
// so nothing has to be tidied when sessions are moved or deleted.
extension PlannedWorkout {
    /// The other sessions of this one's brick, in the order they are done.
    public var brickMates: [PlannedWorkout] {
        guard let brickID else { return [] }
        return (plan?.workouts ?? [])
            .filter { $0 !== self && $0.brickID == brickID && $0.date == date }
            .sorted(by: Self.inDayOrder)
    }

    public var isInBrick: Bool { !brickMates.isEmpty }

    /// The session this one is done straight after.
    public var brickLeader: PlannedWorkout? {
        brickMates.last { Self.inDayOrder($0, self) }
    }

    /// Puts this session straight after `leader`, on its day and in its brick, or takes it
    /// out of its brick when `leader` is nil.
    public func follow(_ leader: PlannedWorkout?) {
        if let current = brickID, leader?.brickID != current {
            // A brick of one is not a brick.
            let left = brickMates
            if left.count == 1 { left[0].brickID = nil }
            brickID = nil
        }
        guard let leader, leader !== self else { return }
        let id = leader.brickID ?? UUID()
        leader.brickID = id
        brickID = id
        date = leader.date

        var order = (leader.plan?.workouts ?? [])
            .filter { $0.date == date && $0 !== self }
            .sorted(by: Self.inDayOrder)
        order.insert(self, at: (order.firstIndex { $0 === leader } ?? order.count - 1) + 1)
        for (position, session) in order.enumerated() where session.orderInDay != position {
            session.orderInDay = position
        }
    }
}

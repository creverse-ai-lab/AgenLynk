import Foundation

/// Places a call/response capsule beside the event node that anchors the row.
/// The node always belongs to the child session, so moving the capsule toward
/// the parent leaves a deterministic gap instead of letting the two pills
/// overlap around the midpoint between adjacent lanes.
enum SequenceRelationLayout {
    static func centerX(
        parentX: Double,
        childX: Double,
        eventNodeWidth: Double,
        relationWidth: Double,
        spacing: Double
    ) -> Double {
        guard parentX != childX else { return childX }

        let direction = childX > parentX ? 1.0 : -1.0
        let laneDistance = abs(childX - parentX)
        let collisionFreeDistance = eventNodeWidth / 2 + relationWidth / 2 + spacing
        let distanceKeepingCapsulePastParent = max(0, laneDistance - relationWidth / 2)
        let distanceFromChild = min(collisionFreeDistance, distanceKeepingCapsulePastParent)
        return childX - direction * distanceFromChild
    }
}

enum SequencePageLayout {
    static func range(totalCount: Int, page: Int, pageSize: Int) -> Range<Int> {
        guard totalCount > 0, pageSize > 0 else { return 0..<0 }
        let safePage = max(0, page)
        let end = max(0, totalCount - safePage * pageSize)
        let start = max(0, end - pageSize)
        return start..<end
    }

    static func entries<Value>(in values: [Value], page: Int, pageSize: Int) -> ArraySlice<Value> {
        values[range(totalCount: values.count, page: page, pageSize: pageSize)]
    }
}

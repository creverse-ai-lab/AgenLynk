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

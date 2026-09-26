import Foundation

@main
enum SequenceRelationLayoutChecks {
    static func main() throws {
        try checkAdjacentLaneSpacing()
        try checkMirroredLaneSpacing()
        try checkLongerSubagentLabel()
        print("Swift sequence relation layout checks passed")
    }

    private static func checkAdjacentLaneSpacing() throws {
        let x = SequenceRelationLayout.centerX(
            parentX: 0,
            childX: 220,
            eventNodeWidth: 196,
            relationWidth: 88,
            spacing: 8
        )
        try requireGap(parentX: 0, childX: 220, relationX: x, eventWidth: 196, relationWidth: 88, expected: 8)
    }

    private static func checkMirroredLaneSpacing() throws {
        let x = SequenceRelationLayout.centerX(
            parentX: 220,
            childX: 0,
            eventNodeWidth: 196,
            relationWidth: 58,
            spacing: 8
        )
        try requireGap(parentX: 220, childX: 0, relationX: x, eventWidth: 196, relationWidth: 58, expected: 8)
    }

    private static func checkLongerSubagentLabel() throws {
        let x = SequenceRelationLayout.centerX(
            parentX: 0,
            childX: 220,
            eventNodeWidth: 196,
            relationWidth: 112,
            spacing: 8
        )
        try requireGap(parentX: 0, childX: 220, relationX: x, eventWidth: 196, relationWidth: 112, expected: 8)
    }

    private static func requireGap(
        parentX: Double,
        childX: Double,
        relationX: Double,
        eventWidth: Double,
        relationWidth: Double,
        expected: Double
    ) throws {
        let direction = childX > parentX ? 1.0 : -1.0
        let relationNearEdge = relationX + direction * relationWidth / 2
        let eventNearEdge = childX - direction * eventWidth / 2
        let gap = direction * (eventNearEdge - relationNearEdge)
        guard abs(gap - expected) < 0.001 else {
            throw SequenceRelationLayoutError.failed("expected gap \(expected), got \(gap)")
        }
    }
}

private enum SequenceRelationLayoutError: Error {
    case failed(String)
}

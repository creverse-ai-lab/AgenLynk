import Foundation

@main
enum SequenceRelationLayoutChecks {
    static func main() throws {
        try checkAdjacentLaneSpacing()
        try checkMirroredLaneSpacing()
        try checkLongerSubagentLabel()
        try checkPageScope()
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

    private static func checkPageScope() throws {
        let values = Array(0..<45)
        guard Array(SequencePageLayout.entries(in: values, page: 0, pageSize: 20)) == Array(25..<45),
              Array(SequencePageLayout.entries(in: values, page: 1, pageSize: 20)) == Array(5..<25),
              Array(SequencePageLayout.entries(in: values, page: 2, pageSize: 20)) == Array(0..<5),
              SequencePageLayout.range(totalCount: 0, page: 0, pageSize: 20).isEmpty else {
            throw SequenceRelationLayoutError.failed("pagination must expose only the current page's events")
        }
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

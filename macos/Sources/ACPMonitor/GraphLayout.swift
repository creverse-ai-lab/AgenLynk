import Foundation

/// The dashboard 그래프 view's geometry: a calm, static node-link drawing of
/// the delegation tree (Frontdoor → Worker → nested Worker), laid out left to
/// right by depth with siblings stacked top to bottom. No physics and no
/// animation — the same input always lands on the same spot, so a growing
/// tree only adds rows instead of reshuffling what the reader already found.
///
/// Classic tidy layout: every leaf takes the next row, a parent sits halfway
/// between its first and last child. Subtrees never share rows, so nodes in
/// one column never overlap. Pure, so it is tested without SwiftUI.
struct GraphLayout: Equatable, Sendable {
    struct Metrics: Equatable, Sendable {
        var nodeWidth: Double = 176
        var nodeHeight: Double = 46
        var columnGap: Double = 44
        var rowGap: Double = 10
        /// Space between two trees stacked in one drawing.
        var groupGap: Double = 26
        /// Room above each tree for its Frontdoor label; 0 draws none.
        var groupHeaderHeight: Double = 0
        var padding: Double = 16
    }

    /// One session to place: depth-first order, parent before child.
    struct Input: Equatable, Sendable {
        let id: String
        let parentId: String?
        let depth: Int
    }

    /// One tree (a Frontdoor's sessions) of the drawing.
    struct Group: Equatable, Sendable {
        let id: String
        let nodes: [Input]
    }

    struct Node: Identifiable, Equatable, Sendable {
        let id: String
        let groupId: String
        let parentId: String?
        let depth: Int
        /// Top-left corner; the size is the metrics' node size.
        let x: Double
        let y: Double
    }

    struct Edge: Identifiable, Equatable, Sendable {
        let from: String
        let to: String
        var id: String { "\(from)>\(to)" }
    }

    struct PlacedGroup: Identifiable, Equatable, Sendable {
        let id: String
        /// Top of the group's header (or of its first node without one).
        let y: Double
        let height: Double
    }

    let metrics: Metrics
    let nodes: [Node]
    let edges: [Edge]
    let groups: [PlacedGroup]
    let width: Double
    let height: Double

    var isEmpty: Bool { nodes.isEmpty }

    static func make(groups input: [Group], metrics: Metrics = Metrics()) -> GraphLayout {
        var nodes: [Node] = []
        var edges: [Edge] = []
        var placedGroups: [PlacedGroup] = []
        var cursor = metrics.padding
        var maxDepth = 0
        let rowStep = metrics.nodeHeight + metrics.rowGap

        // A session is drawn once, in the first tree that lists it.
        var drawn = Set<String>()
        for group in input {
            let members = group.nodes.filter { !drawn.contains($0.id) }
            guard !members.isEmpty else { continue }
            let groupTop = cursor
            cursor += metrics.groupHeaderHeight
            var byId: [String: Input] = [:]
            for node in members where byId[node.id] == nil { byId[node.id] = node }
            var children: [String: [String]] = [:]
            var tops: [String] = []
            var listed = Set<String>()
            for node in members where listed.insert(node.id).inserted {
                if let parent = node.parentId, parent != node.id, byId[parent] != nil {
                    children[parent, default: []].append(node.id)
                } else {
                    tops.append(node.id)
                }
            }

            var centers: [String: Double] = [:]
            var visited = Set<String>()
            // Returns the node's vertical center; leaves take the next row.
            // The column is the drawn parent's plus one (a top keeps its own
            // depth), so a child is always right of the node its edge leaves.
            func place(_ id: String, depth: Int, parent: String?) -> Double {
                guard visited.insert(id).inserted, byId[id] != nil else { return centers[id] ?? cursor }
                let childCenters = (children[id] ?? [])
                    .filter { !visited.contains($0) }
                    .map { place($0, depth: depth + 1, parent: id) }
                let center: Double
                if let first = childCenters.first, let last = childCenters.last {
                    center = (first + last) / 2
                } else {
                    center = cursor + metrics.nodeHeight / 2
                    cursor += rowStep
                }
                centers[id] = center
                maxDepth = max(maxDepth, depth)
                nodes.append(Node(
                    id: id,
                    groupId: group.id,
                    parentId: parent,
                    depth: depth,
                    x: metrics.padding + Double(depth) * (metrics.nodeWidth + metrics.columnGap),
                    y: center - metrics.nodeHeight / 2
                ))
                return center
            }
            for top in tops { _ = place(top, depth: max(0, byId[top]?.depth ?? 0), parent: nil) }
            // A cycle leaves members no top reaches; they still get a row.
            for node in members where !visited.contains(node.id) { _ = place(node.id, depth: max(0, node.depth), parent: nil) }

            drawn.formUnion(visited)
            let groupBottom = cursor - metrics.rowGap
            placedGroups.append(PlacedGroup(id: group.id, y: groupTop, height: groupBottom - groupTop))
            cursor = groupBottom + metrics.groupGap
        }

        // Depth-first order reads top to bottom; keep that for the views.
        nodes.sort { lhs, rhs in lhs.y != rhs.y ? lhs.y < rhs.y : lhs.x < rhs.x }
        let placed = Set(nodes.map(\.id))
        for node in nodes {
            if let parent = node.parentId, placed.contains(parent) {
                edges.append(Edge(from: parent, to: node.id))
            }
        }
        let height = nodes.isEmpty ? 0 : cursor - metrics.groupGap + metrics.padding
        let width = nodes.isEmpty ? 0 : metrics.padding * 2
            + Double(maxDepth + 1) * metrics.nodeWidth + Double(maxDepth) * metrics.columnGap
        return GraphLayout(metrics: metrics, nodes: nodes, edges: edges, groups: placedGroups, width: width, height: height)
    }
}

/// What the 그래프 view draws: the layout plus the sessions and Frontdoors
/// its nodes and tree labels stand for. Built once per monitor revision and
/// scope (AppModel.dashboardGraph).
struct DashboardGraph: Equatable, Sendable {
    let layout: GraphLayout
    let sessions: [String: GatewaySession]
    /// The Frontdoor (or history group) each tree stands for, by group id.
    let frontdoors: [String: FrontdoorSession]

    static let empty = DashboardGraph(layout: GraphLayout.make(groups: []), sessions: [:], frontdoors: [:])

    /// One tree per Frontdoor, from the same `SessionTree` resolution the
    /// sequence and the menu bar use. Labels each tree when there are several.
    static func make(frontdoors: [FrontdoorSession]) -> DashboardGraph {
        var metrics = GraphLayout.Metrics()
        if frontdoors.count > 1 { metrics.groupHeaderHeight = 24 }
        var sessions: [String: GatewaySession] = [:]
        var groups: [GraphLayout.Group] = []
        for frontdoor in frontdoors {
            let tree = SessionTree.order(frontdoor.members, firstRootId: frontdoor.root?.sessionId)
            for node in tree where sessions[node.session.sessionId] == nil { sessions[node.session.sessionId] = node.session }
            groups.append(GraphLayout.Group(
                id: frontdoor.id,
                nodes: tree.map { GraphLayout.Input(id: $0.session.sessionId, parentId: $0.parentSessionId, depth: $0.depth) }
            ))
        }
        return DashboardGraph(
            layout: GraphLayout.make(groups: groups, metrics: metrics),
            sessions: sessions,
            frontdoors: Dictionary(frontdoors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        )
    }
}

import ACPShared
import Foundation

private enum CheckError: Error { case failed(String) }

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckError.failed(message) }
}

@main
struct GraphLayoutTests {
    static func main() throws {
        try columnsFollowDepth()
        try siblingsStackInOrderAndParentsCenter()
        try fortyNodesNeverOverlap()
        try treesStackWithoutSharingRows()
        try cyclesAndDuplicatesStillDrawOnce()
        try dashboardGraphFollowsSessionTree()
        try partitionKeepsAncestorsOfMovingWorkers()
        try partitionFortyNodes()
        try dashboardGraphBoxesRestingWorkers()
        try sequenceHidesRestingLanes()
        print("Swift graph layout checks passed")
    }

    private static func input(_ id: String, _ parent: String?, _ depth: Int) -> GraphLayout.Input {
        GraphLayout.Input(id: id, parentId: parent, depth: depth)
    }

    private static func node(_ layout: GraphLayout, _ id: String) throws -> GraphLayout.Node {
        guard let node = layout.nodes.first(where: { $0.id == id }) else { throw CheckError.failed("node \(id) missing") }
        return node
    }

    private static func overlaps(_ layout: GraphLayout) -> Bool {
        let m = layout.metrics
        for (index, a) in layout.nodes.enumerated() {
            for b in layout.nodes[(index + 1)...] {
                let apart = a.x + m.nodeWidth <= b.x || b.x + m.nodeWidth <= a.x
                    || a.y + m.nodeHeight <= b.y || b.y + m.nodeHeight <= a.y
                if !apart { return true }
            }
        }
        return false
    }

    private static func columnsFollowDepth() throws {
        let layout = GraphLayout.make(groups: [GraphLayout.Group(id: "g", nodes: [
            input("root", nil, 0), input("w1", "root", 1), input("w2", "w1", 2), input("w3", "w2", 3)
        ])])
        let m = layout.metrics
        for (id, depth) in [("root", 0), ("w1", 1), ("w2", 2), ("w3", 3)] {
            let placed = try node(layout, id)
            try check(placed.depth == depth, "\(id) is drawn at depth \(depth)")
            try check(placed.x == m.padding + Double(depth) * (m.nodeWidth + m.columnGap), "\(id) sits in its depth's column")
        }
        try check(layout.edges.map(\.id) == ["root>w1", "w1>w2", "w2>w3"], "one edge per parent link, got \(layout.edges.map(\.id))")
        try check(layout.width == m.padding * 2 + 4 * m.nodeWidth + 3 * m.columnGap, "width covers four columns")
    }

    private static func siblingsStackInOrderAndParentsCenter() throws {
        let layout = GraphLayout.make(groups: [GraphLayout.Group(id: "g", nodes: [
            input("root", nil, 0), input("a", "root", 1), input("a1", "a", 2), input("b", "root", 1), input("c", "root", 1)
        ])])
        let a = try node(layout, "a"), b = try node(layout, "b"), c = try node(layout, "c"), root = try node(layout, "root")
        try check(a.y < b.y && b.y < c.y, "siblings stack top to bottom in the given order")
        try check(root.y == (a.y + c.y) / 2, "a parent sits halfway between its first and last child")
        let a1 = try node(layout, "a1")
        try check(a1.y == a.y, "an only child shares its parent's row")
        try check(zip(layout.nodes, layout.nodes.dropFirst()).allSatisfy { $0.y <= $1.y }, "nodes are listed top to bottom")
    }

    private static func fortyNodesNeverOverlap() throws {
        // A Frontdoor with 12 Workers, most of them with nested Workers.
        var nodes = [input("root", nil, 0)]
        var count = 1
        var worker = 0
        while count < 40 {
            let id = "w\(worker)"
            nodes.append(input(id, "root", 1))
            count += 1
            for child in 0..<(worker % 3) where count < 40 {
                nodes.append(input("\(id).\(child)", id, 2))
                count += 1
                if child == 1, count < 40 {
                    nodes.append(input("\(id).\(child).x", "\(id).\(child)", 3))
                    count += 1
                }
            }
            worker += 1
        }
        let layout = GraphLayout.make(groups: [GraphLayout.Group(id: "g", nodes: nodes)])
        try check(layout.nodes.count == 40, "all 40 nodes are placed, got \(layout.nodes.count)")
        try check(!overlaps(layout), "no two nodes overlap")
        try check(layout.edges.count == 39, "every non-root node has its edge")
        let m = layout.metrics
        try check(layout.nodes.allSatisfy { $0.x + m.nodeWidth <= layout.width && $0.y + m.nodeHeight <= layout.height },
                  "the drawing's size contains every node")

        let flat = GraphLayout.make(groups: [GraphLayout.Group(id: "g", nodes: [input("root", nil, 0)]
            + (1..<40).map { input("f\($0)", "root", 1) })])
        try check(!overlaps(flat) && flat.nodes.count == 40, "39 sibling Workers stack without overlap")
        try check(flat.width == m.padding * 2 + 2 * m.nodeWidth + m.columnGap, "a flat tree stays two columns wide")
    }

    private static func treesStackWithoutSharingRows() throws {
        var metrics = GraphLayout.Metrics()
        metrics.groupHeaderHeight = 24
        let layout = GraphLayout.make(groups: [
            GraphLayout.Group(id: "one", nodes: [input("r1", nil, 0), input("x", "r1", 1), input("y", "r1", 1)]),
            GraphLayout.Group(id: "empty", nodes: []),
            GraphLayout.Group(id: "two", nodes: [input("r2", nil, 0)])
        ], metrics: metrics)
        try check(layout.groups.map(\.id) == ["one", "two"], "an empty tree takes no room")
        let first = layout.groups[0], second = layout.groups[1]
        try check(second.y >= first.y + first.height + metrics.groupGap, "the second tree starts below the first")
        let r2 = try node(layout, "r2")
        try check(r2.y >= second.y + metrics.groupHeaderHeight, "a tree's nodes sit under its label")
        try check(r2.groupId == "two" && layout.edges.allSatisfy { $0.to != "r2" }, "trees are not linked to each other")
        try check(!overlaps(layout), "stacked trees do not overlap")
    }

    private static func cyclesAndDuplicatesStillDrawOnce() throws {
        let layout = GraphLayout.make(groups: [
            GraphLayout.Group(id: "g", nodes: [input("a", "b", 1), input("b", "a", 1), input("a", nil, 0)]),
            GraphLayout.Group(id: "h", nodes: [input("a", nil, 0), input("z", nil, 0)])
        ])
        try check(layout.nodes.map(\.id).sorted() == ["a", "b", "z"], "every session is drawn once, got \(layout.nodes.map(\.id))")
        try check(!overlaps(layout), "a parent cycle does not stack nodes on each other")
        try check(layout.edges.count == 1, "a cycle draws one edge, not two")
        try check(GraphLayout.make(groups: []).isEmpty && GraphLayout.make(groups: []).height == 0, "nothing to draw is empty")
    }

    private static func session(
        _ id: String, role: String = "worker", parent: String? = nil, status: String = "running", created: String
    ) throws -> GatewaySession {
        var object: [String: JSONValue] = [
            "sessionId": .string(id), "provider": .string("claude"), "status": .string(status),
            "openerInstanceId": .string("main"), "role": .string(role), "createdAt": .string(created),
            "updatedAt": .string(created)
        ]
        if let parent { object["parentSessionId"] = .string(parent) }
        guard let value = GatewaySession(.object(object)) else { throw CheckError.failed("session \(id) did not decode") }
        return value
    }

    private static func dashboardGraphFollowsSessionTree() throws {
        let sessions = [
            try session("root", role: "frontdoor", created: "2026-09-26T00:00:00.000Z"),
            try session("late", parent: "root", created: "2026-09-26T00:03:00.000Z"),
            try session("early", parent: "root", created: "2026-09-26T00:01:00.000Z"),
            try session("nested", parent: "early", created: "2026-09-26T00:02:00.000Z")
        ]
        let frontdoors = FrontdoorSession.make(sessions: sessions)
        let graph = DashboardGraph.make(frontdoors: frontdoors)
        let layout = graph.layout
        let nested = try node(layout, "nested"), early = try node(layout, "early"), late = try node(layout, "late")
        try check(nested.depth == 2, "a nested Worker is two columns in")
        try check(early.y < late.y, "siblings follow creation order, like SessionTree")
        try check(Set(graph.sessions.keys) == ["root", "late", "early", "nested"], "every node has its session")
        try check(layout.metrics.groupHeaderHeight == 0, "one Frontdoor needs no tree label")
    }

    private static func partitionKeepsAncestorsOfMovingWorkers() throws {
        // root → idle → running, root → idle leaf, root → closed → idle leaf.
        let nodes = [
            input("root", nil, 0), input("idle", "root", 1), input("run", "idle", 2),
            input("leaf", "root", 1), input("closed", "root", 1), input("deep", "closed", 2)
        ]
        let split = GraphLayout.partition(nodes, anchors: ["root", "run"])
        try check(split.tree.map(\.id) == ["root", "idle", "run"], "an idle parent of a running child stays, got \(split.tree.map(\.id))")
        try check(split.resting.map(\.id) == ["leaf", "closed", "deep"], "resting leaves and subtrees are boxed in order, got \(split.resting.map(\.id))")
        try check(split.tree.count + split.resting.count == nodes.count, "every node lands on one side")
        let layout = GraphLayout.make(groups: [GraphLayout.Group(id: "g", nodes: split.tree)])
        try check(layout.edges.map(\.id) == ["root>idle", "idle>run"], "the kept chain keeps its edges")

        let none = GraphLayout.partition(nodes, anchors: Set(nodes.map(\.id)))
        try check(none.resting.isEmpty && none.tree == nodes, "all moving boxes nothing")
        let onlyRoot = GraphLayout.partition(nodes, anchors: ["root"])
        try check(onlyRoot.tree.map(\.id) == ["root"] && onlyRoot.resting.count == 5, "an idle tree keeps only its Frontdoor")
        let cycle = GraphLayout.partition([input("a", "b", 1), input("b", "a", 1), input("c", "a", 2)], anchors: ["c"])
        try check(Set(cycle.tree.map(\.id)) == ["a", "b", "c"] && cycle.resting.isEmpty, "a parent cycle still ends the walk")
    }

    private static func partitionFortyNodes() throws {
        // A Frontdoor with 13 Workers of 2 nested each; one nested Worker runs.
        var nodes = [input("root", nil, 0)]
        for worker in 0..<13 {
            nodes.append(input("w\(worker)", "root", 1))
            nodes.append(input("w\(worker).a", "w\(worker)", 2))
            nodes.append(input("w\(worker).b", "w\(worker)", 2))
        }
        try check(nodes.count == 40, "the case has 40 nodes")
        let split = GraphLayout.partition(nodes, anchors: ["root", "w7.b"])
        try check(split.tree.map(\.id) == ["root", "w7", "w7.b"], "only the moving chain is drawn, got \(split.tree.map(\.id))")
        try check(split.resting.count == 37, "the other 37 rest in the box, got \(split.resting.count)")
        let layout = GraphLayout.make(groups: [GraphLayout.Group(id: "g", nodes: split.tree)])
        try check(layout.nodes.count == 3 && !overlaps(layout), "the trimmed tree lays out without overlap")
    }

    private static func dashboardGraphBoxesRestingWorkers() throws {
        let sessions = [
            try session("root", role: "frontdoor", status: "idle", created: "2026-09-26T00:00:00.000Z"),
            try session("parent", parent: "root", status: "idle", created: "2026-09-26T00:01:00.000Z"),
            try session("child", parent: "parent", status: "waiting_permission", created: "2026-09-26T00:02:00.000Z"),
            try session("done", parent: "root", status: "closed", created: "2026-09-26T00:03:00.000Z"),
            try session("rest", parent: "root", status: "idle", created: "2026-09-26T00:04:00.000Z"),
            try session("err", parent: "root", status: "error", created: "2026-09-26T00:05:00.000Z")
        ]
        let graph = DashboardGraph.make(frontdoors: FrontdoorSession.make(sessions: sessions))
        try check(Set(graph.layout.nodes.map(\.id)) == ["root", "parent", "child", "err"],
                  "the Frontdoor, moving Workers and their ancestors are drawn, got \(graph.layout.nodes.map(\.id))")
        try check(graph.resting.flatMap(\.nodes).map(\.id) == ["done", "rest"], "idle and closed leaves are boxed, got \(graph.resting.flatMap(\.nodes).map(\.id))")
        try check(graph.restingCount == 2, "the box counts its Workers")
        try check(graph.sessions["done"] != nil, "a boxed Worker keeps its session for its chip")
    }

    private static func sequenceHidesRestingLanes() throws {
        let sessions = [
            try session("root", role: "frontdoor", status: "idle", created: "2026-09-26T00:00:00.000Z"),
            try session("parent", parent: "root", status: "idle", created: "2026-09-26T00:01:00.000Z"),
            try session("child", parent: "parent", status: "running", created: "2026-09-26T00:02:00.000Z"),
            try session("done", parent: "root", status: "closed", created: "2026-09-26T00:03:00.000Z"),
            try session("doneKid", parent: "done", status: "idle", created: "2026-09-26T00:03:30.000Z"),
            try session("rest", parent: "root", status: "idle", created: "2026-09-26T00:04:00.000Z")
        ]
        let lanes = SessionTree.order(sessions, firstRootId: "root")
        let hidden = MenuBarPipeline.restingLaneIds(lanes, selectedSessionId: nil)
        try check(hidden == ["done", "doneKid", "rest"], "resting Worker lanes hide, the moving chain and Frontdoor stay, got \(hidden.sorted())")
        let selected = MenuBarPipeline.restingLaneIds(lanes, selectedSessionId: "doneKid")
        try check(selected == ["rest"], "the selected lane and its parent stay, got \(selected.sorted())")
        // A top-level Worker lane (no Frontdoor in view) is never hidden.
        let orphan = try session("orphan", status: "idle", created: "2026-09-26T00:05:00.000Z")
        let orphanLanes = SessionTree.order([orphan])
        try check(MenuBarPipeline.restingLaneIds(orphanLanes, selectedSessionId: nil).isEmpty, "a top-level lane stays")
    }
}

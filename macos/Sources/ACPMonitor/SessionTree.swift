import Foundation

/// The delegation tree of a set of sessions: Frontdoor → Worker → nested
/// Worker. The menu bar pipeline and the dashboard sequence both lay sessions
/// out from this one resolution, so they can never disagree on who called
/// whom or how deep a Worker sits.
enum SessionTree {
    struct Node: Equatable, Sendable {
        let session: GatewaySession
        /// The parent among the ordered sessions, nil for a top-level one.
        let parentSessionId: String?
        /// 0 = a Frontdoor (or a top-level Worker without one).
        let depth: Int
    }

    /// A session's parent within `sessions`: its explicit `parentSessionId`
    /// when that session is present, else (for a Worker) the Frontdoor root
    /// that opened it. A session is never its own parent.
    static func parentResolver(_ sessions: [GatewaySession]) -> (GatewaySession) -> String? {
        var byId: [String: GatewaySession] = [:]
        var rootsByOpener: [String: GatewaySession] = [:]
        for session in sessions {
            if byId[session.sessionId] == nil { byId[session.sessionId] = session }
            guard session.isFrontdoorRecord, let opener = session.openerInstanceId else { continue }
            // The newest record of a Frontdoor is its root, as FrontdoorSession.make picks it.
            if let current = rootsByOpener[opener], (current.updatedAt ?? "") >= (session.updatedAt ?? "") { continue }
            rootsByOpener[opener] = session
        }
        return { session in
            if let explicit = session.parentSessionId, explicit != session.sessionId, byId[explicit] != nil {
                return explicit
            }
            guard !session.isFrontdoorRecord,
                  let opener = session.openerInstanceId,
                  let root = rootsByOpener[opener],
                  root.sessionId != session.sessionId else { return nil }
            return root.sessionId
        }
    }

    /// Depth-first order: parent before child, siblings by creation.
    /// `firstRootId` (a Frontdoor's root) leads the top level; the other tops
    /// follow by creation. A session caught in a parent cycle is not dropped:
    /// it hangs one level down, like a Worker whose parent is unknown.
    static func order(_ sessions: [GatewaySession], firstRootId: String? = nil) -> [Node] {
        let parentOf = parentResolver(sessions)
        var seen = Set<String>()
        let members = sessions.filter { seen.insert($0.sessionId).inserted }
        var children: [String: [GatewaySession]] = [:]
        var tops: [GatewaySession] = []
        for session in members {
            if let parent = parentOf(session) {
                children[parent, default: []].append(session)
            } else {
                tops.append(session)
            }
        }
        let byCreation: (GatewaySession, GatewaySession) -> Bool = { ($0.createdAt ?? "") < ($1.createdAt ?? "") }
        tops.sort { lhs, rhs in
            let lhsFirst = lhs.sessionId == firstRootId
            let rhsFirst = rhs.sessionId == firstRootId
            if lhsFirst != rhsFirst { return lhsFirst }
            return byCreation(lhs, rhs)
        }
        var nodes: [Node] = []
        nodes.reserveCapacity(members.count)
        var visited = Set<String>()
        func visit(_ session: GatewaySession, parent: String?, depth: Int) {
            guard visited.insert(session.sessionId).inserted else { return }
            nodes.append(Node(session: session, parentSessionId: parent, depth: depth))
            for child in (children[session.sessionId] ?? []).sorted(by: byCreation) {
                visit(child, parent: session.sessionId, depth: depth + 1)
            }
        }
        for top in tops { visit(top, parent: nil, depth: 0) }
        for session in members.sorted(by: byCreation) where !visited.contains(session.sessionId) {
            visit(session, parent: nil, depth: 1)
        }
        return nodes
    }

    /// The sessions named by `ids` plus every ancestor of theirs, in the
    /// order `sessions` lists them.
    static func withAncestors(of ids: Set<String>, in sessions: [GatewaySession]) -> [GatewaySession] {
        let parentOf = parentResolver(sessions)
        var byId: [String: GatewaySession] = [:]
        for session in sessions where byId[session.sessionId] == nil { byId[session.sessionId] = session }
        var included = ids
        var pending = Array(ids)
        while let id = pending.popLast() {
            guard let session = byId[id], let parent = parentOf(session) else { continue }
            if included.insert(parent).inserted { pending.append(parent) }
        }
        var seen = Set<String>()
        return sessions.filter { included.contains($0.sessionId) && seen.insert($0.sessionId).inserted }
    }
}

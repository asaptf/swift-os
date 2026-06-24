// SPDX-License-Identifier: Apache-2.0
// endpoints_test.swift — SC5 host acceptance for the endpoints loop (cases 7, 8, 10 +
// the ready-only registration of cases 1/2/10), deterministic.
//
// Drives the leader-gated, level-triggered EndpointsLoop against an in-process cubestore.
// Cell statuses are written straight into /status/cells/ the way `slet` reports them (the
// probe half is the sibling probe_test); the loop converges /endpoints/<service> from
// them. These cases prove the controller half of SC5: only a READY Cell is an endpoint,
// services are grouped with deterministic sorted output, only the leader writes, the loop
// is level-triggered (a re-run never churns a stable set), and a Cell that stops being
// ready or is torn down loses its endpoint. Foundation is used only by the harness.
//
// Cases (per the SC5 ladder):
//   1/2 ready → endpoint registered; not ready → never registered (the core property)
//   7   grouping: 3 ready Cells of an app → 3 sorted endpoints; scale + readiness changes
//       add/remove correctly; a second service is grouped separately
//   8   leader-only + level-triggered: a follower writes nothing; a re-run (reconnect/
//       restart) converges from status with NO churn (the endpoint revision is stable)
//   10  removal: a Cell torn down (status goes terminal / not ready) → endpoint removed;
//       the service key is deleted when its last ready Cell goes away

import Foundation

let nodeAddr = "10.0.2.15"

@main struct EndpointsTest {
    static var failed = false
    static func check(_ cond: Bool, _ msg: String) {
        if !cond { FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8)); failed = true }
    }

    static func main() {
        case1_2_readyOnly()
        case7_grouping()
        case8_leaderAndLevelTriggered()
        case10_removal()

        if failed { FileHandle.standardError.write(Data("endpoints-test: FAILED\n".utf8)); exit(1) }
        print("endpoints-test: all SC5 endpoints cases (1/2, 7, 8, 10) passed")
    }

    // MARK: - Fixture

    final class Fixture {
        let store = openRamCubeStore()

        func putStatus(_ st: CellStatusRecord) {
            _ = store.apply([.put(key: SletKeys.status(st.cellId), value: st.encode())])
        }
        func removeStatus(_ cid: String) {
            _ = store.apply([.delete(key: SletKeys.status(cid))])
        }
        func loop(isLeader: Bool = true) -> EndpointsLoop<RamLog, RamSnapshot> {
            EndpointsLoop(store: store, isLeader: isLeader)
        }
        func endpoints(_ service: String) -> [Endpoint]? {
            guard let e = store.get(EndpointKeys.endpoints(service)) else { return nil }
            return EndpointSet.decode(e.value)?.endpoints
        }
        func endpointRev(_ service: String) -> Revision? {
            store.get(EndpointKeys.endpoints(service))?.modRevision
        }
    }

    // MARK: - Builders

    static func st(_ cid: String, service: String, port: UInt16 = 8080, ready: Bool,
                   address: String = nodeAddr, phase: CellPhase = .running) -> CellStatusRecord {
        CellStatusRecord(cellId: cid, node: "node-a", phase: phase, ready: ready, restartCount: 0,
                         imageDigest: [UInt8](repeating: 0, count: 32), startedAtSeconds: 1, message: "",
                         service: service, address: address, port: port)
    }

    // MARK: - Case 1/2: only ready Cells become endpoints

    static func case1_2_readyOnly() {
        let f = Fixture()
        f.putStatus(st("web--r1-s0-g1", service: "web", ready: true))
        f.putStatus(st("web--r1-s1-g1", service: "web", ready: false))   // not ready → excluded
        f.loop().step()

        guard let eps = f.endpoints("web") else { check(false, "1/2: endpoints written"); return }
        check(eps.count == 1, "1/2: only the ready Cell is an endpoint (got \(eps.count))")
        check(eps.first?.cellId == "web--r1-s0-g1", "1/2: the ready Cell is registered")
        check(eps.first?.address == nodeAddr && eps.first?.port == 8080, "1/2: endpoint carries address:port")
    }

    // MARK: - Case 7: grouping, scale, readiness changes, separate services

    static func case7_grouping() {
        let f = Fixture()
        // 3 ready Cells of app "web" (deliberately inserted out of order) + one of "api".
        f.putStatus(st("web--r1-s2-g1", service: "web", ready: true))
        f.putStatus(st("web--r1-s0-g1", service: "web", ready: true))
        f.putStatus(st("web--r1-s1-g1", service: "web", ready: true))
        f.putStatus(st("api--r1-s0-g1", service: "api", port: 9000, ready: true))
        f.loop().step()

        guard let web = f.endpoints("web") else { check(false, "7: web endpoints"); return }
        check(web.count == 3, "7: 3 ready Cells → 3 endpoints")
        check(web.map { $0.cellId } == ["web--r1-s0-g1", "web--r1-s1-g1", "web--r1-s2-g1"],
              "7: endpoints sorted deterministically by cellId")
        check(f.endpoints("api")?.count == 1, "7: a second service is grouped separately")

        // Scale up: a 4th ready Cell joins.
        f.putStatus(st("web--r1-s3-g1", service: "web", ready: true))
        f.loop().step()
        check(f.endpoints("web")?.count == 4, "7: scale up → endpoint added")

        // Readiness change: one Cell goes not-ready → removed.
        f.putStatus(st("web--r1-s1-g1", service: "web", ready: false))
        f.loop().step()
        let after = f.endpoints("web")?.map { $0.cellId } ?? []
        check(after == ["web--r1-s0-g1", "web--r1-s2-g1", "web--r1-s3-g1"],
              "7: a Cell going not-ready is removed; the rest stay sorted")
    }

    // MARK: - Case 8: leader-only + level-triggered (no churn)

    static func case8_leaderAndLevelTriggered() {
        let f = Fixture()
        f.putStatus(st("web--r1-s0-g1", service: "web", ready: true))

        // A follower writes nothing.
        f.loop(isLeader: false).step()
        check(f.endpoints("web") == nil, "8: a follower writes no endpoints")

        // The leader programs the set.
        f.loop().step()
        check(f.endpoints("web")?.count == 1, "8: the leader programs endpoints")
        guard let rev1 = f.endpointRev("web") else { check(false, "8: endpoint revision"); return }

        // Re-run (reconnect/restart): level-triggered, converges from the SAME status with no
        // churn — the endpoint set is byte-identical so the CAS write is skipped.
        f.loop().step()
        f.loop().step()
        check(f.endpointRev("web") == rev1, "8: re-running the loop does NOT churn a stable endpoint set")
    }

    // MARK: - Case 10: removal (teardown / status gone)

    static func case10_removal() {
        let f = Fixture()
        f.putStatus(st("web--r1-s0-g1", service: "web", ready: true))
        f.putStatus(st("web--r1-s1-g1", service: "web", ready: true))
        f.loop().step()
        check(f.endpoints("web")?.count == 2, "10: two endpoints registered")

        // One Cell torn down: slet writes a terminal, not-ready status (assignment deleted).
        f.putStatus(st("web--r1-s1-g1", service: "web", ready: false, phase: .dead(exitCode: 0)))
        f.loop().step()
        check(f.endpoints("web")?.map { $0.cellId } == ["web--r1-s0-g1"], "10: torn-down Cell's endpoint removed")

        // The last ready Cell also goes away (status deleted) → the service key is deleted.
        f.removeStatus("web--r1-s0-g1")
        f.loop().step()
        check(f.endpoints("web") == nil, "10: no ready Cell left → /endpoints/web deleted")
    }
}

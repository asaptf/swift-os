// SPDX-License-Identifier: Apache-2.0
// cubestore_test.swift — host unit test for swiftcube/cubestore (SC0).
//
// Compiled with the host Swift toolchain against the Foundation-free cubestore
// core plus the host POSIX-file sink, then run with no arguments. Covers the 11
// SC0 acceptance cases: MVCC put/get/delete, range/prefix + as-of reads,
// revision monotonicity, atomic batches, compare-and-apply, live watch + cancel,
// watch-from-past replay, compaction, WAL recovery, snapshot+truncate recovery,
// and torn-record recovery. Pass `--bench` for the optional microbench (kept off
// the pass/fail path). Mirrors tests/handle_test.swift's harness style.
//
// The sink files live under a fresh temp directory per recovery case so reopen
// exercises real on-disk recovery with an honest fsync.

import Foundation

typealias Store = CubeStore<PosixAppendLog, PosixSnapshotStore>

@main
struct CubestoreTest {
    static var failed = false

    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failed = true
        }
    }

    // MARK: helpers

    static func b(_ s: String) -> Bytes { Array(s.utf8) }
    static func str(_ b: Bytes) -> String { String(decoding: b, as: UTF8.self) }

    static func freshDir() -> String {
        let dir = NSTemporaryDirectory() + "cubestore-test-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    static func openStore(_ dir: String) -> Store {
        try! Store.open(log: PosixAppendLog(path: dir + "/wal.log"),
                        snapshot: PosixSnapshotStore(dir: dir))
    }

    static func main() {
        case1_putGetDelete()
        case2_rangePrefixMVCC()
        case3_revisionMonotonicity()
        case4_atomicBatch()
        case5_compareAndApply()
        case6_watchLive()
        case7_watchFromPast()
        case8_compaction()
        case9_walRecovery()
        case10_snapshotRecovery()
        case11_tornRecordRecovery()

        if CommandLine.arguments.contains("--bench") { microbench() }

        if failed {
            FileHandle.standardError.write(Data("cubestore-test: FAILED\n".utf8))
            exit(1)
        }
        print("cubestore-test: all 11 cases passed")
    }

    // 1. put/get/delete; Entry carries correct create/mod/version.
    static func case1_putGetDelete() {
        let s = openStore(freshDir())
        check(s.apply([.put(key: b("a"), value: b("1"))]) == 1, "1: first put → rev 1")
        var e = s.get(b("a"))
        check(e?.value == b("1") && e?.createRevision == 1 && e?.modRevision == 1 && e?.version == 1,
              "1: create/mod/version at first put")

        check(s.apply([.put(key: b("a"), value: b("2"))]) == 2, "1: update → rev 2")
        e = s.get(b("a"))
        check(e?.value == b("2") && e?.createRevision == 1 && e?.modRevision == 2 && e?.version == 2,
              "1: createRevision stable, version bumps on update")

        check(s.apply([.delete(key: b("a"))]) == 3, "1: delete → rev 3")
        check(s.get(b("a")) == nil, "1: deleted key reads nil")

        check(s.apply([.put(key: b("a"), value: b("3"))]) == 4, "1: revive → rev 4")
        e = s.get(b("a"))
        check(e?.createRevision == 4 && e?.version == 1, "1: revived key gets fresh createRevision/version")
    }

    // 2. range + prefix ordered; MVCC read atRevision returns historical state.
    static func case2_rangePrefixMVCC() {
        let s = openStore(freshDir())
        s.apply([.put(key: b("/a"), value: b("1")),
                 .put(key: b("/c"), value: b("3")),
                 .put(key: b("/b"), value: b("2"))])           // rev 1
        let r = s.range(b("/a"), b("/c"))                       // half-open [/a,/c)
        check(r.map { str($0.key) } == ["/a", "/b"], "2: range is ordered + half-open")

        s.apply([.put(key: b("/x"), value: b("9")), .put(key: b("/ab"), value: b("7"))]) // rev 2
        let p = s.prefix(b("/a"))
        check(p.map { str($0.key) } == ["/a", "/ab"], "2: prefix scan ordered")

        s.apply([.put(key: b("/a"), value: b("100"))])         // rev 3
        check(s.get(b("/a"))?.value == b("100"), "2: latest read")
        check(s.get(b("/a"), atRevision: 1)?.value == b("1"), "2: as-of read returns historical value")
        check(s.get(b("/x"), atRevision: 1) == nil, "2: as-of read sees key absent before its create")
    }

    // 3. revision monotonicity: each apply bumps by exactly 1; empty no bump.
    static func case3_revisionMonotonicity() {
        let s = openStore(freshDir())
        check(s.apply([]) == 0, "3: empty batch on fresh store stays at 0")
        check(s.apply([.put(key: b("k"), value: b("v"))]) == 1, "3: bump to 1")
        check(s.apply([]) == 1, "3: empty batch does not bump")
        check(s.apply([.put(key: b("k"), value: b("v2"))]) == 2, "3: bump to 2")
        check(s.revision == 2, "3: revision is 2")
    }

    // 4. atomic batch: a multi-key apply is all-or-nothing under one revision.
    static func case4_atomicBatch() {
        let s = openStore(freshDir())
        let rev = s.apply([.put(key: b("k1"), value: b("a")),
                           .put(key: b("k2"), value: b("b")),
                           .put(key: b("k3"), value: b("c"))])
        check(rev == 1, "4: one batch → one revision")
        check(s.get(b("k1"))?.modRevision == 1 &&
              s.get(b("k2"))?.modRevision == 1 &&
              s.get(b("k3"))?.modRevision == 1, "4: all keys share the batch revision")
    }

    // 5. compareAndApply: passing conditions commit; failing leave state untouched.
    static func case5_compareAndApply() {
        let s = openStore(freshDir())
        // Optimistic create: commit iff the key is absent.
        let ok = s.compareAndApply(conditions: [.keyAbsent(key: b("lock"))],
                                   [.put(key: b("lock"), value: b("held"))])
        check(ok.committed && ok.revision == 1, "5: create-if-absent commits")

        // Stale CAS: condition on a wrong modRevision must fail and not bump.
        let stale = s.compareAndApply(conditions: [.modRevisionEquals(key: b("lock"), 999)],
                                      [.put(key: b("lock"), value: b("stolen"))])
        check(!stale.committed && stale.revision == 1, "5: failing condition does not commit/bump")
        check(s.get(b("lock"))?.value == b("held"), "5: state untouched after failed CAS")

        // Correct CAS: condition on the real modRevision commits.
        let cur = s.get(b("lock"))!.modRevision
        let win = s.compareAndApply(conditions: [.modRevisionEquals(key: b("lock"), cur)],
                                    [.put(key: b("lock"), value: b("renewed"))])
        check(win.committed && win.revision == 2, "5: matching-modRevision CAS commits")
        check(s.get(b("lock"))?.value == b("renewed"), "5: value updated by CAS")
    }

    // 6. watch live: events in revision order; deletes emit delete events; cancel stops.
    static func case6_watchLive() {
        let s = openStore(freshDir())
        var seen: [Event] = []
        let h = try! s.watchPrefix(b("/svc/"), fromRevision: s.revision) { seen.append($0) }

        s.apply([.put(key: b("/svc/a"), value: b("1"))])       // rev 1
        s.apply([.put(key: b("/other"), value: b("x"))])       // rev 2 (out of range)
        s.apply([.put(key: b("/svc/b"), value: b("2")),
                 .put(key: b("/svc/a"), value: b("1b"))])      // rev 3 (two events, key order)
        s.apply([.delete(key: b("/svc/a"))])                   // rev 4

        check(seen.count == 4, "6: only in-range events delivered (\(seen.count))")
        check(seen.map { $0.modRevision } == [1, 3, 3, 4], "6: events in revision order")
        check(seen[1].key == b("/svc/a") && seen[2].key == b("/svc/b"),
              "6: same-revision events ordered by key")
        if case .delete(let k, let r) = seen[3] {
            check(k == b("/svc/a") && r == 4, "6: delete emits a delete event")
        } else { check(false, "6: last event is a delete") }

        h.cancel()
        s.apply([.put(key: b("/svc/c"), value: b("3"))])       // rev 5, after cancel
        check(seen.count == 4, "6: cancel stops delivery")
    }

    // 7. watch from past revision: replays only modRevision > R, then live; no gaps/dups.
    static func case7_watchFromPast() {
        let s = openStore(freshDir())
        s.apply([.put(key: b("/k/1"), value: b("a"))])         // rev 1
        s.apply([.put(key: b("/k/2"), value: b("b"))])         // rev 2
        s.apply([.put(key: b("/k/3"), value: b("c"))])         // rev 3
        let watchFrom: Revision = 1

        var seen: [Event] = []
        _ = try! s.watchPrefix(b("/k/"), fromRevision: watchFrom) { seen.append($0) }
        // History replay: events with modRevision > 1 → revs 2,3 only (not rev 1).
        check(seen.map { $0.modRevision } == [2, 3], "7: replays only modRevision > R")

        s.apply([.put(key: b("/k/4"), value: b("d"))])         // rev 4, live
        check(seen.map { $0.modRevision } == [2, 3, 4], "7: continues live with no gap or dup")
        check(seen.count == Set(seen.map { $0.modRevision }).count, "7: no duplicate revisions")
    }

    // 8. compaction: compact(rev), watch below the floor ⇒ Compacted; current reads unaffected.
    static func case8_compaction() {
        let s = openStore(freshDir())
        s.apply([.put(key: b("k"), value: b("v1"))])           // rev 1
        s.apply([.put(key: b("k"), value: b("v2"))])           // rev 2
        s.apply([.put(key: b("k"), value: b("v3"))])           // rev 3
        s.compact(upTo: 2)
        check(s.compactedRevision == 2, "8: compaction floor recorded")

        // Current read is unaffected.
        check(s.get(b("k"))?.value == b("v3"), "8: current value survives compaction")

        // Watching from below the floor is Compacted.
        var threw = false
        do { _ = try s.watchPrefix(b("k"), fromRevision: 1) { _ in } }
        catch CubeError.compacted(let at) { threw = (at == 2) }
        catch { threw = false }
        check(threw, "8: watch from below compaction floor throws .compacted")

        // Watching from at/above the floor still works.
        var ok = true
        do { _ = try s.watchPrefix(b("k"), fromRevision: 2) { _ in } } catch { ok = false }
        check(ok, "8: watch from the floor is allowed")
    }

    // 9. WAL recovery: apply N, sync, reopen ⇒ identical keyspace and revision.
    static func case9_walRecovery() {
        let dir = freshDir()
        do {
            let s = openStore(dir)
            s.apply([.put(key: b("/a"), value: b("1"))])
            s.apply([.put(key: b("/b"), value: b("2"))])
            s.apply([.delete(key: b("/a"))])
            s.apply([.put(key: b("/c"), value: b("3"))])
            s.sync()
        }
        let s2 = openStore(dir)                                 // reopen from the same sink
        check(s2.revision == 4, "9: revision recovered (\(s2.revision))")
        check(s2.get(b("/a")) == nil, "9: deleted key stays deleted after recovery")
        check(s2.get(b("/b"))?.value == b("2"), "9: value recovered")
        check(s2.get(b("/c"))?.value == b("3"), "9: later value recovered")
        check(s2.range(b(""), nil).map { str($0.key) } == ["/b", "/c"], "9: keyspace identical")
    }

    // 10. snapshot + truncate + recover: state via snapshot + WAL tail.
    static func case10_snapshotRecovery() {
        let dir = freshDir()
        do {
            let s = openStore(dir)
            s.apply([.put(key: b("/x"), value: b("1"))])        // rev 1
            s.apply([.put(key: b("/y"), value: b("2"))])        // rev 2
            s.snapshot()                                        // checkpoint at rev 2, WAL truncated
            s.apply([.put(key: b("/z"), value: b("3"))])        // rev 3, post-snapshot WAL tail
            s.apply([.put(key: b("/x"), value: b("1b"))])       // rev 4
            s.sync()
        }
        let s2 = openStore(dir)
        check(s2.revision == 4, "10: revision via snapshot + WAL tail (\(s2.revision))")
        check(s2.get(b("/x"))?.value == b("1b"), "10: snapshot key updated by WAL tail")
        check(s2.get(b("/y"))?.value == b("2"), "10: snapshot-only key recovered")
        check(s2.get(b("/z"))?.value == b("3"), "10: post-snapshot key recovered")
    }

    // 11. torn-record recovery: corrupt the final WAL record ⇒ reopen at last good revision.
    static func case11_tornRecordRecovery() {
        let dir = freshDir()
        do {
            let s = openStore(dir)
            s.apply([.put(key: b("k1"), value: b("a"))])        // rev 1
            s.apply([.put(key: b("k2"), value: b("b"))])        // rev 2
            s.apply([.put(key: b("k3"), value: b("c"))])        // rev 3 (to be torn)
            s.sync()
        }
        // Truncate the last byte of the WAL → the final record is partial.
        let wal = dir + "/wal.log"
        let fh = FileHandle(forUpdatingAtPath: wal)!
        let size = fh.seekToEndOfFile()
        fh.truncateFile(atOffset: size - 1)
        fh.closeFile()

        let s2 = openStore(dir)
        check(s2.revision == 2, "11: reopen at last good revision (\(s2.revision))")
        check(s2.get(b("k1"))?.value == b("a") && s2.get(b("k2"))?.value == b("b"),
              "11: good records survive")
        check(s2.get(b("k3")) == nil, "11: torn trailing record discarded")
        // The log was repaired to the last good boundary; a fresh append is clean.
        s2.apply([.put(key: b("k4"), value: b("d"))])
        s2.sync()
        let s3 = openStore(dir)
        check(s3.revision == 3 && s3.get(b("k4"))?.value == b("d"),
              "11: appends after a torn-tail repair recover cleanly")
    }

    // Optional microbench (off the pass/fail path): put ops/sec + watch fan-out.
    static func microbench() {
        let s = openStore(freshDir())
        let n = 50_000
        let start = Date()
        for i in 0..<n { s.apply([.put(key: b("/bench/\(i)"), value: b("v"))]) }
        let dt = -start.timeIntervalSinceNow
        print(String(format: "bench: %d puts in %.3fs = %.0f ops/sec", n, dt, Double(n) / dt))

        var delivered = 0
        for _ in 0..<100 { _ = try! s.watchPrefix(b("/bench/"), fromRevision: s.revision) { _ in delivered += 1 } }
        let t2 = Date()
        s.apply([.put(key: b("/bench/live"), value: b("x"))])
        let dt2 = -t2.timeIntervalSinceNow
        print(String(format: "bench: fan-out to 100 watchers delivered %d events in %.6fs", delivered, dt2))
    }
}

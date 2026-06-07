// SPDX-License-Identifier: Apache-2.0
// security.swift - minimal principal/session/capability core (M12a).
//
// This is the first kernel-native security model scaffold. It deliberately does
// not implement Unix uid==0 authority. Every process carries an explicit
// principal id, session id, and capability mask; later milestones will load
// principals from the base image and enforce capabilities in VFS/process code.

// A per-process domain tag for future Cells (see docs/CAPABILITIES.md —
// Cell-as-composition). This is a lightweight identifier the process carries,
// NOT a heavyweight kernel Cell object; M0–M13 all run in the single global
// cell, and adding real Cells later becomes a struct-field change, not a
// schema migration.
struct CellId: Equatable { var raw: UInt32 }
let globalCell = CellId(raw: 1)   // the single default/global cell; M0–M13 all run here

struct ProcessSecurityContext {
    var principal: UInt32
    var session: UInt32
    var caps: UInt64
    var cell: CellId
}

let capConsole: UInt64 = 1 << 0
let capSpawn: UInt64 = 1 << 1
let capFsRead: UInt64 = 1 << 2
let capTmpWrite: UInt64 = 1 << 3
let capProcessInspect: UInt64 = 1 << 4
let capNet: UInt64 = 1 << 5         // open network sockets (net-b)

private let bootPrincipal: UInt32 = 1
private let bootSession: UInt32 = 1

func securityInit() {
    uartPuts("M12a security: boot principal console session 1\n")
}

func securityBootContext() -> ProcessSecurityContext {
    ProcessSecurityContext(principal: bootPrincipal,
                           session: bootSession,
                           caps: capConsole | capSpawn | capFsRead | capTmpWrite | capProcessInspect | capNet,
                           cell: globalCell)
}


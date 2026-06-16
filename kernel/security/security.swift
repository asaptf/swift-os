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

// Each process carries an *effective* identity (principal/session/caps — what it
// can do right now) and a *real* identity (who invoked it). They are equal for
// an ordinary process; they diverge only after a setuid-on-exec (see
// `securityApplySetuid`), the swift-os analogue of Unix ruid/euid. `/bin/sudo`
// reads the real identity (via security_info_ex) to learn the invoker while
// running with the file owner's effective authority.
struct ProcessSecurityContext {
    var principal: UInt32
    var session: UInt32
    var caps: UInt64
    var cell: CellId
    var realPrincipal: UInt32
    var realSession: UInt32
    var realCaps: UInt64
}

let capConsole: UInt64 = 1 << 0
let capSpawn: UInt64 = 1 << 1
let capFsRead: UInt64 = 1 << 2
let capTmpWrite: UInt64 = 1 << 3
let capProcessInspect: UInt64 = 1 << 4
let capNet: UInt64 = 1 << 5         // open network sockets (net-b)
let capLogExport: UInt64 = 1 << 6   // future log ring export / sink install authority

// The full root capability set: every capability the boot context holds. A
// setuid-on-exec elevation grants exactly this (the only setuid binaries live in
// the signed base image and are root-owned, so setuid means "gain root").
let capAllRoot: UInt64 = capConsole | capSpawn | capFsRead | capTmpWrite | capProcessInspect | capNet

// File mode bit that marks a base-image binary setuid (octal 4000), mirroring
// Unix S_ISUID. Only honored for files served from the read-only signed image.
let modeSetuid: UInt32 = 0o4000

private let bootPrincipal: UInt32 = 1
private let bootSession: UInt32 = 1

func securityInit() {
    uartPuts("M12a security: boot principal console session 1\n")
}

func securityBootContext() -> ProcessSecurityContext {
    ProcessSecurityContext(principal: bootPrincipal,
                           session: bootSession,
                           caps: capAllRoot,
                           cell: globalCell,
                           realPrincipal: bootPrincipal,
                           realSession: bootSession,
                           realCaps: capAllRoot)
}

/// Apply a setuid-on-exec elevation to an existing context: the *effective*
/// identity becomes the file owner with full root authority, while the *real*
/// identity preserves who invoked the program. The session is unchanged — like
/// Unix euid, only the privilege identity is swapped, not the login session.
func securityApplySetuid(_ ctx: ProcessSecurityContext, owner: UInt32) -> ProcessSecurityContext {
    var next = ctx
    next.realPrincipal = ctx.principal
    next.realSession = ctx.session
    next.realCaps = ctx.caps
    next.principal = owner
    next.caps = capAllRoot
    return next
}

/// Re-establish the real==effective invariant after an ordinary (non-setuid)
/// exec, so a program that dropped privilege via login() and then exec'd reports
/// a consistent real identity.
func securitySyncRealToEffective(_ ctx: ProcessSecurityContext) -> ProcessSecurityContext {
    var next = ctx
    next.realPrincipal = ctx.principal
    next.realSession = ctx.session
    next.realCaps = ctx.caps
    return next
}

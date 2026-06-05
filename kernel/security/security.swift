// security.swift - minimal principal/session/capability core (M12a).
//
// This is the first kernel-native security model scaffold. It deliberately does
// not implement Unix uid==0 authority. Every process carries an explicit
// principal id, session id, and capability mask; later milestones will load
// principals from the base image and enforce capabilities in VFS/process code.

struct ProcessSecurityContext {
    var principal: UInt32
    var session: UInt32
    var caps: UInt64
}

let capConsole: UInt64 = 1 << 0
let capSpawn: UInt64 = 1 << 1
let capFsRead: UInt64 = 1 << 2
let capTmpWrite: UInt64 = 1 << 3
let capProcessInspect: UInt64 = 1 << 4

private let bootPrincipal: UInt32 = 1
private let bootSession: UInt32 = 1

func securityInit() {
    uartPuts("M12a security: boot principal console session 1\n")
}

func securityBootContext() -> ProcessSecurityContext {
    ProcessSecurityContext(principal: bootPrincipal,
                           session: bootSession,
                           caps: capConsole | capSpawn | capFsRead | capTmpWrite | capProcessInspect)
}


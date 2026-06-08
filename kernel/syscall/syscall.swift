// SPDX-License-Identifier: Apache-2.0
// syscall.swift — tiny POSIX-like syscall dispatcher.

private let sysOpen: UInt = 1
private let sysRead: UInt = 2
private let sysWrite: UInt = 3
private let sysClose: UInt = 4
private let sysExit: UInt = 5
private let sysLseek: UInt = 6
private let sysTcGetAttr: UInt = 7  // tcgetattr(fd, termios*)
private let sysTcSetAttr: UInt = 8  // tcsetattr(fd, actions, termios*)
private let sysSigaction: UInt = 9  // sigaction(sig, handler)
private let sysKill: UInt = 10      // kill(pid, sig)
private let sysGetpid: UInt = 11    // getpid()
private let sysSpawn: UInt = 12     // spawn(path, argv) -> child exit status
private let sysWaitpid: UInt = 13   // waitpid(pid, status*, options)
private let sysFork: UInt = 20      // fork() -> child pid (0 in child)
private let sysStat: UInt = 14      // stat(path, statbuf)
private let sysFstat: UInt = 15     // fstat(fd, statbuf)
private let sysGetdents: UInt = 16  // getdents(fd, buf, count)
private let sysChdir: UInt = 17     // chdir(path)
private let sysGetcwd: UInt = 18    // getcwd(buf, size)
private let sysSbrk: UInt = 19      // sbrk(incr) -> previous break
private let sysExecve: UInt = 21    // execve(path, argv, envp)
private let sysPsInfo: UInt = 22    // psinfo(buffer, capacity) -> total processes
private let sysDup: UInt = 23       // dup(fd)
private let sysDup2: UInt = 24      // dup2(oldfd, newfd)
private let sysPipe: UInt = 25      // pipe(int fds[2])
private let sysPoll: UInt = 26      // poll(pollfd*, nfds, timeout_ms)
private let sysUnlink: UInt = 27    // unlink(path)
private let sysRename: UInt = 28    // rename(old, new)
private let sysMkdir: UInt = 29     // mkdir(path, mode)
private let sysRmdir: UInt = 30     // rmdir(path)
private let sysSecurityInfo: UInt = 31 // security_info(struct security_info*)
private let sysLogin: UInt = 32        // login(principal, session, caps) — needs capConsole
private let sysFtruncate: UInt = 33    // ftruncate(fd, length) — tmpfs file resize (busybox vi)
private let sysFcntl: UInt = 34        // fcntl(fd, cmd, arg) — F_DUPFD(_CLOEXEC)/GETFD/SETFD/GETFL (shell redirects)
private let sysChmod: UInt = 35        // chmod(path, mode) — tmpfs only
private let sysChown: UInt = 36        // chown(path, owner) — tmpfs only
private let sysTime: UInt = 37         // time() — Unix seconds from the PL031 RTC
private let sysSocket: UInt = 38       // socket(domain, type, proto) → fd (capNet)
private let sysBind: UInt = 39         // bind(fd, port) — local UDP port
private let sysSendto: UInt = 40       // sendto(fd, &msg) — UDP datagram out
private let sysRecvfrom: UInt = 41     // recvfrom(fd, &msg) — UDP datagram in
private let sysListen: UInt = 42       // listen(fd, backlog) — TCP
private let sysAccept: UInt = 43       // accept(fd) → connection fd — TCP
private let sysConnect: UInt = 44      // connect(fd, ip, port) — TCP active open
private let sysResolve: UInt = 45      // resolve(name, server_ip, server_port) -> ip — DNS
private let sysSysInfo: UInt = 46      // sysinfo(buffer) — system stats for /bin/top
private let sysProcStat: UInt = 47     // procstat(buffer, capacity) — rich per-proc records
private let sysThreadCreate: UInt = 48 // thread_create(entry, arg, stackTop) -> tid (rt-a)
private let sysFutex: UInt = 49        // futex(uaddr, op, val) — minimal WAIT/WAKE (rt-a)
private let sysConfine: UInt = 50      // confine(path) — restrict FS access to a subtree (C3)
private let sysEndpointCreate: UInt = 51 // endpoint_create(ends[2]) — IPC endpoint pair (C4a)
private let sysIpcSend: UInt = 52      // ipc_send(fd, &msg) — bytes + optional handle (C4b)
private let sysIpcRecv: UInt = 53      // ipc_recv(fd, &msg) -> bytes; installs any handle (C4b)
private let sysMmap: UInt = 54         // mmap(len, prot) -> base VA — anonymous mmap (Track B)
private let sysMunmap: UInt = 55       // munmap(addr, len) — unmap+free anonymous pages (Track B)
private let sysMprotect: UInt = 56     // mprotect(addr, len, prot) — change prot, W^X (Track B)
private let sysNanosleep: UInt = 57    // nanosleep(seconds, nanos) — block on the timer tick
private let sysSpawnHandles: UInt = 58 // spawn_handles(path, argv, specs, count) — C2 explicit inheritance

// Our termios layout (must match userland/lib/termios.h): four 32-bit flag
// words; only c_lflag (offset 12) is interpreted today.
private let termiosLflagOffset = 12

func syscallDispatch(number: UInt, frame: UnsafeMutablePointer<UInt>) {
    let result: Int

    if number == sysOpen {
        result = vfsOpen(path: frame[0], flags: frame[1])
    } else if number == sysRead {
        result = vfsRead(fd: Int(bitPattern: frame[0]), buffer: frame[1], count: frame[2])
    } else if number == sysWrite {
        result = vfsWrite(fd: Int(bitPattern: frame[0]), buffer: frame[1], count: frame[2])
    } else if number == sysClose {
        result = vfsClose(fd: Int(bitPattern: frame[0]))
    } else if number == sysExit {
        // A process launched via processRunElf (M6) unwinds back to the kernel;
        // the standalone M5 EL0 probe (no active process) keeps its old banner.
        if processIsActive() {
            processExit(Int(bitPattern: frame[0])) // never returns
        }
        result = 0
        uartPuts("M5 OK: user open/read/write/close completed\n")
    } else if number == sysLseek {
        result = vfsLseek(fd: Int(bitPattern: frame[0]),
                          offset: Int(bitPattern: frame[1]),
                          whence: Int(bitPattern: frame[2]))
    } else if number == sysTcGetAttr {
        result = syscallTcGetAttr(termios: frame[1])
    } else if number == sysTcSetAttr {
        result = syscallTcSetAttr(termios: frame[2])
    } else if number == sysSigaction {
        signalSetDisposition(Int(bitPattern: frame[0]), frame[1])
        result = 0
    } else if number == sysKill {
        // Single foreground process model: deliver to ourselves immediately.
        signalRaise(Int(bitPattern: frame[1]))
        signalDeliverToForeground() // may not return (fatal default action)
        result = 0
    } else if number == sysGetpid {
        result = processCurrentPid()
    } else if number == sysFork {
        result = processFork(frame)
    } else if number == sysExecve {
        let (addr, len) = execResolve(frame[0])
        if addr == 0 {
            result = -2 // ENOENT
        } else {
            let (packed, packedLen, argc) = packUserArgv(frame[1])
            result = processExec(image: addr, size: len, packed: packed,
                                 packedLen: packedLen, argc: argc, frame: frame)
        }
    } else if number == sysSpawn {
        // Resolve + run a child synchronously (spawn = fork+exec+wait combined).
        let (addr, len) = execResolve(frame[0])
        if addr == 0 {
            result = -2 // ENOENT
        } else {
            let (packed, packedLen, argc) = packUserArgv(frame[1])
            result = processSpawnChild(addr, len, packed: packed, packedLen: packedLen, argc: argc)
        }
    } else if number == sysSpawnHandles {
        // C2: same synchronous spawn shape, but the child starts empty and receives
        // exactly the explicit handle specs named by the caller.
        let (addr, len) = execResolve(frame[0])
        if addr == 0 {
            result = -2 // ENOENT
        } else {
            let (packed, packedLen, argc) = packUserArgv(frame[1])
            result = processSpawnChildWithHandles(addr, len, packed: packed,
                                                  packedLen: packedLen, argc: argc,
                                                  specsVA: frame[2], specCount: frame[3])
        }
    } else if number == sysWaitpid {
        result = processWaitpid(Int(bitPattern: frame[0]), frame[1])
    } else if number == sysStat {
        result = vfsStat(path: frame[0], statbuf: frame[1])
    } else if number == sysFstat {
        result = vfsFstat(fd: Int(bitPattern: frame[0]), statbuf: frame[1])
    } else if number == sysGetdents {
        result = vfsGetdents(fd: Int(bitPattern: frame[0]), buffer: frame[1], count: frame[2])
    } else if number == sysChdir {
        result = vfsChdir(path: frame[0])
    } else if number == sysGetcwd {
        result = vfsGetcwd(buffer: frame[0], size: frame[1])
    } else if number == sysSbrk {
        frame[0] = processSbrk(Int(bitPattern: frame[0]))
        return // result already written (sbrk returns an address, not errno)
    } else if number == sysPsInfo {
        result = processSnapshot(buffer: frame[0], capacity: frame[1])
        klogRing(.info, "proc", "psinfo")
    } else if number == sysDup {
        result = vfsDup(fd: Int(bitPattern: frame[0]))
    } else if number == sysDup2 {
        result = vfsDup2(oldfd: Int(bitPattern: frame[0]), newfd: Int(bitPattern: frame[1]))
    } else if number == sysPipe {
        result = vfsPipe(fdsVA: frame[0])
    } else if number == sysPoll {
        result = vfsPoll(fds: frame[0], nfds: frame[1], timeout: Int(bitPattern: frame[2]))
    } else if number == sysUnlink {
        result = vfsUnlink(path: frame[0])
    } else if number == sysRename {
        result = vfsRename(old: frame[0], new: frame[1])
    } else if number == sysMkdir {
        result = vfsMkdir(path: frame[0])
    } else if number == sysRmdir {
        result = vfsRmdir(path: frame[0])
    } else if number == sysSecurityInfo {
        result = processSecurityInfo(buffer: frame[0])
    } else if number == sysLogin {
        result = processLogin(principal: UInt32(truncatingIfNeeded: frame[0]),
                              session: UInt32(truncatingIfNeeded: frame[1]),
                              caps: UInt64(frame[2]))
    } else if number == sysFtruncate {
        result = vfsFtruncate(fd: Int(bitPattern: frame[0]), length: Int(bitPattern: frame[1]))
    } else if number == sysFcntl {
        result = vfsFcntl(fd: Int(bitPattern: frame[0]), cmd: Int(bitPattern: frame[1]),
                          arg: Int(bitPattern: frame[2]))
    } else if number == sysChmod {
        result = vfsChmod(path: frame[0], mode: frame[1])
    } else if number == sysChown {
        result = vfsChown(path: frame[0], owner: frame[1])
    } else if number == sysTime {
        frame[0] = UInt(rtcNow())
        return // returns a time value, not an errno
    } else if number == sysSocket {
        result = vfsSocket(domain: Int(bitPattern: frame[0]),
                           type: Int(bitPattern: frame[1]),
                           proto: Int(bitPattern: frame[2]))
    } else if number == sysBind {
        result = vfsSocketBind(fd: Int(bitPattern: frame[0]), port: Int(bitPattern: frame[1]))
    } else if number == sysSendto {
        result = vfsSendto(fd: Int(bitPattern: frame[0]), msgVA: frame[1])
    } else if number == sysRecvfrom {
        result = vfsRecvfrom(fd: Int(bitPattern: frame[0]), msgVA: frame[1])
    } else if number == sysListen {
        result = vfsListen(fd: Int(bitPattern: frame[0]), backlog: Int(bitPattern: frame[1]))
    } else if number == sysAccept {
        result = vfsAccept(fd: Int(bitPattern: frame[0]))
    } else if number == sysConnect {
        result = vfsConnect(fd: Int(bitPattern: frame[0]), ip: frame[1], port: Int(bitPattern: frame[2]))
    } else if number == sysResolve {
        frame[0] = UInt(vfsResolve(nameVA: frame[0], serverIP: frame[1], serverPort: Int(bitPattern: frame[2])))
        return  // returns an IPv4 value (0 = failure), not an errno
    } else if number == sysSysInfo {
        result = processSysInfo(buffer: frame[0])
    } else if number == sysProcStat {
        result = processStatSnapshot(buffer: frame[0], capacity: frame[1])
    } else if number == sysThreadCreate {
        result = processThreadCreate(entryVA: frame[0], argVA: frame[1], stackTopVA: frame[2])
    } else if number == sysFutex {
        result = futexOp(uaddrVA: frame[0], op: Int(bitPattern: frame[1]), val: frame[2])
    } else if number == sysConfine {
        result = vfsConfine(path: frame[0])
    } else if number == sysEndpointCreate {
        result = vfsEndpointCreate(endsVA: frame[0])
    } else if number == sysIpcSend {
        result = vfsIpcSend(fd: Int(bitPattern: frame[0]), msgVA: frame[1])
    } else if number == sysIpcRecv {
        result = vfsIpcRecv(fd: Int(bitPattern: frame[0]), msgVA: frame[1])
    } else if number == sysMmap {
        // Returns a base VA on success or a negative errno (encoded in the UInt,
        // in [-4095, -1]); the userland bridge maps that to MAP_FAILED + errno.
        frame[0] = processMmap(frame[1], Int32(truncatingIfNeeded: frame[2]))
        return // result is an address, not an errno
    } else if number == sysMunmap {
        result = processMunmap(frame[0], frame[1])
    } else if number == sysMprotect {
        result = processMprotect(frame[0], frame[1], Int32(truncatingIfNeeded: frame[2]))
    } else if number == sysNanosleep {
        result = processNanosleep(seconds: frame[0], nanos: frame[1])
    } else {
        result = -38 // ENOSYS
    }

    frame[0] = UInt(bitPattern: result)
}

private func syscallTcGetAttr(termios ptr: UInt) -> Int {
    guard let base = userWritableBuffer(ptr, 16) else { return -22 }
    let words = UnsafeMutableRawPointer(mutating: base)
    // Zero the four flag words, then publish the current c_lflag.
    words.storeBytes(of: UInt32(0), toByteOffset: 0, as: UInt32.self)
    words.storeBytes(of: UInt32(0), toByteOffset: 4, as: UInt32.self)
    words.storeBytes(of: UInt32(0), toByteOffset: 8, as: UInt32.self)
    words.storeBytes(of: ttyGetLflag(), toByteOffset: termiosLflagOffset, as: UInt32.self)
    return 0
}

private func syscallTcSetAttr(termios ptr: UInt) -> Int {
    guard let base8 = userReadableBuffer(ptr, 16) else { return -22 }
    let base = UnsafeRawPointer(base8)
    let lflag = base.load(fromByteOffset: termiosLflagOffset, as: UInt32.self)
    ttySetLflag(lflag)
    return 0
}

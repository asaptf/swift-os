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
private let sysIpcSend: UInt = 52      // ipc_send(fd, &msg) — bytes + optional handle (C4a)
private let sysIpcRecv: UInt = 53      // ipc_recv(fd, &msg) -> bytes; installs any handle (C4a)
private let sysMmap: UInt = 54         // mmap(addr, len, prot, flags) -> base VA — anonymous mmap (Track B)
private let sysMunmap: UInt = 55       // munmap(addr, len) — unmap+free anonymous pages (Track B)
private let sysMprotect: UInt = 56     // mprotect(addr, len, prot) — change prot, W^X (Track B)
private let sysNanosleep: UInt = 57    // nanosleep(seconds, nanos) — block on the timer tick
private let sysSpawnHandles: UInt = 58 // spawn_handles(path, argv, specs, count) — C2 explicit inheritance
private let sysMmapFile: UInt = 59     // mmap_file(fd, len, prot) -> base VA — file-backed read-only (I2a)
private let sysPkgInstall: UInt = 60   // pkg_install(fd, name, version_revision) — append+activate package
private let sysPkgInfo: UInt = 61      // pkg_info(index, buf, cap) — active package summary
private let sysDeviceClaim: UInt = 62  // device_claim(name, info*) -> fd (C5b opaque grant)
private let sysDeviceInfo: UInt = 63   // device_info(fd, info*) -> 0 (C5b metadata)
private let sysDeviceDiscover: UInt = 64 // device_discover(index, info*) -> 0 (C5c manifest)
private let sysUpdateConfirm: UInt = 65 // update_confirm() — mark the booted A/B slot healthy (U1c); needs capConsole
private let sysUpdateActivate: UInt = 66 // update_activate() — promote the inactive A/B slot (U1e); needs capConsole
private let sysUpdateStage: UInt = 67    // update_stage() — copy the payload disk into the inactive A/B slot (U1f-2b); needs capConsole
private let sysKernelStage: UInt = 68    // kernel_stage() — copy the active kernel slot image into the inactive ESP slot (U1g-4c); needs capConsole
private let sysKernelActivate: UInt = 69 // kernel_activate() — flip the active kernel slot in kernel-state (U1g-5d); needs capConsole
private let sysKernelConfirm: UInt = 70  // kernel_confirm() — mark the booted ESP kernel slot healthy (U1g-5c); needs capConsole
private let sysEventfd: UInt = 71         // eventfd(initval, flags) — event notification counter
private let sysPkgStreamBegin: UInt = 72  // pkg_stream_begin(desc) — start streamed package payload install
private let sysPkgStreamWrite: UInt = 73  // pkg_stream_write(buf, len) — append payload bytes to package store
private let sysPkgStreamCommit: UInt = 74 // pkg_stream_commit() — verify, publish, and activate streamed package
private let sysPkgStreamAbort: UInt = 75  // pkg_stream_abort() — discard the active streamed package install
private let sysSigreturn: UInt = 76       // sigreturn() — restore a kernel-built user signal frame
private let sysLogRead: UInt = 77         // log_read(buf, cap, max_count) — needs capLogExport
private let sysSocketpair: UInt = 78      // socketpair(fds, flags) — local full-duplex fd pair
private let sysPkgFiles: UInt = 79        // pkg_files(name, buf, cap) — list active package payload files
private let sysRandom: UInt = 80          // random(buf, cap) — runtime entropy from virtio-rng
private let sysPkgRemove: UInt = 81       // pkg_remove(name) — deactivate package on next boot
private let sysLogStats: UInt = 82        // log_stats(buf, cap) — needs capLogExport
private let sysNetInfo: UInt = 83         // netinfo(buffer, cap) — network status snapshot
private let sysOpenpty: UInt = 84         // openpty(master*, slave*) — pseudo-terminal pair (HC34)
private let sysPtySetForeground: UInt = 85 // pty_set_foreground(fd, pid) — tty signal target (HC36)
private let sysSecurityInfoEx: UInt = 86   // security_info_ex(struct*) — effective + real identity (sudo)
private let sysFsync: UInt = 87           // fsync(fd)/fdatasync(fd) — flush the fd's filesystem to media (D2)
private let sysSync: UInt = 88            // sync() — flush all writable filesystems to media (D2)

// Our termios layout (must match userland/lib/termios.h): four 32-bit flag
// words; only c_lflag (offset 12) is interpreted today.
private let termiosLflagOffset = 12
private let logStatsSize = 32

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
        let sig = Int(bitPattern: frame[0])
        if signalIsValid(sig) {
            signalSetDisposition(sig, frame[1], frame[2])
            result = 0
        } else {
            result = -22
        }
    } else if number == sysSigreturn {
        processSignalReturn(frame)
        return
    } else if number == sysKill {
        result = processKill(Int(bitPattern: frame[0]), Int(bitPattern: frame[1]))
    } else if number == sysGetpid {
        result = processCurrentPid()
    } else if number == sysFork {
        result = processFork(frame)
    } else if number == sysExecve {
        let ex = execResolve(frame[0])
        if ex.addr == 0 {
            result = -2 // ENOENT
        } else {
            let (packed, packedLen, argc) = packUserArgv(frame[1])
            let (envPacked, envPackedLen, envc) = packUserArgv(frame[2])
            result = processExec(image: ex.addr, size: ex.len, packed: packed,
                                 packedLen: packedLen, argc: argc,
                                 envPacked: envPacked, envPackedLen: envPackedLen,
                                 envc: envc, setuid: ex.setuid, setuidOwner: ex.owner,
                                 frame: frame)
        }
    } else if number == sysSpawn {
        // Resolve + run a child synchronously (spawn = fork+exec+wait combined).
        let ex = execResolve(frame[0])
        if ex.addr == 0 {
            result = -2 // ENOENT
        } else {
            let (packed, packedLen, argc) = packUserArgv(frame[1])
            result = processSpawnChild(ex.addr, ex.len, packed: packed, packedLen: packedLen,
                                       argc: argc, setuid: ex.setuid, setuidOwner: ex.owner)
        }
    } else if number == sysSpawnHandles {
        // C2: same synchronous spawn shape, but the child starts empty and receives
        // exactly the explicit handle specs named by the caller.
        let ex = execResolve(frame[0])
        if ex.addr == 0 {
            result = -2 // ENOENT
        } else {
            let (packed, packedLen, argc) = packUserArgv(frame[1])
            result = processSpawnChildWithHandles(ex.addr, ex.len, packed: packed,
                                                  packedLen: packedLen, argc: argc,
                                                  specsVA: frame[2], specCount: frame[3],
                                                  setuid: ex.setuid, setuidOwner: ex.owner)
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
    } else if number == sysSecurityInfoEx {
        result = processSecurityInfoEx(buffer: frame[0])
    } else if number == sysLogin {
        result = processLogin(principal: UInt32(truncatingIfNeeded: frame[0]),
                              session: UInt32(truncatingIfNeeded: frame[1]),
                              caps: UInt64(frame[2]))
    } else if number == sysFtruncate {
        result = vfsFtruncate(fd: Int(bitPattern: frame[0]), length: Int(bitPattern: frame[1]))
    } else if number == sysFsync {
        result = vfsFsync(fd: Int(bitPattern: frame[0]))
    } else if number == sysSync {
        result = vfsSyncAll()
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
        result = processSysInfo(buffer: frame[0], capacity: frame[1])
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
        frame[0] = processMmap(frame[0], frame[1], Int32(truncatingIfNeeded: frame[2]),
                               Int32(truncatingIfNeeded: frame[3]))
        return // result is an address, not an errno
    } else if number == sysMmapFile {
        // File-backed read-only mmap (I2a). Like mmap, the result is an address
        // (base VA) or a negative errno encoded in the UInt, not a plain errno.
        frame[0] = processMmapFile(Int(bitPattern: frame[0]), frame[1], Int32(truncatingIfNeeded: frame[2]))
        return
    } else if number == sysPkgInstall {
        result = pkgStoreInstall(fd: Int(bitPattern: frame[0]), nameVA: frame[1], versionVA: frame[2])
    } else if number == sysPkgInfo {
        result = pkgStoreActiveInfo(Int(bitPattern: frame[0]), frame[1], frame[2])
    } else if number == sysPkgFiles {
        result = pkgStoreActiveFiles(nameVA: frame[0], outVA: frame[1], cap: frame[2])
    } else if number == sysPkgRemove {
        result = pkgStoreRemove(nameVA: frame[0])
    } else if number == sysNetInfo {
        result = netInfoSnapshot(buffer: frame[0], capacity: frame[1])
    } else if number == sysPkgStreamBegin {
        result = pkgStoreStreamBegin(descVA: frame[0])
    } else if number == sysPkgStreamWrite {
        result = pkgStoreStreamWrite(bufVA: frame[0], count: frame[1])
    } else if number == sysPkgStreamCommit {
        result = pkgStoreStreamCommit()
    } else if number == sysPkgStreamAbort {
        result = pkgStoreStreamAbort()
    } else if number == sysDeviceClaim {
        result = vfsDeviceClaim(name: frame[0], info: frame[1])
    } else if number == sysDeviceInfo {
        result = vfsDeviceInfo(fd: Int(bitPattern: frame[0]), info: frame[1])
    } else if number == sysDeviceDiscover {
        result = vfsDeviceDiscover(index: Int(bitPattern: frame[0]), info: frame[1])
    } else if number == sysMunmap {
        result = processMunmap(frame[0], frame[1])
    } else if number == sysMprotect {
        result = processMprotect(frame[0], frame[1], Int32(truncatingIfNeeded: frame[2]))
    } else if number == sysNanosleep {
        result = processNanosleep(seconds: frame[0], nanos: frame[1])
    } else if number == sysEventfd {
        result = vfsEventfd(initval: frame[0], flags: frame[1])
    } else if number == sysUpdateConfirm {
        result = updateStoreConfirm() // U1c: capConsole-gated A/B health-confirm
    } else if number == sysUpdateActivate {
        result = updateStoreActivateOther() // U1e: capConsole-gated promote inactive slot
    } else if number == sysUpdateStage {
        result = updateStoreStagePayload() // U1f-2b: capConsole-gated payload→inactive slot copy
    } else if number == sysKernelStage {
        result = espStageActiveToInactive() // U1g-4c: capConsole-gated kernel-slot stage on the ESP
    } else if number == sysKernelActivate {
        result = espActivateOtherKernel() // U1g-5d: capConsole-gated kernel-slot flip via kernel-state
    } else if number == sysKernelConfirm {
        result = espConfirmBootedKernel() // U1g-5c: capConsole-gated kernel-slot health-confirm
    } else if number == sysLogRead {
        result = syscallLogRead(buffer: frame[0], capacity: frame[1], maxCount: frame[2])
    } else if number == sysLogStats {
        result = syscallLogStats(buffer: frame[0], capacity: frame[1])
    } else if number == sysOpenpty {
        result = vfsOpenpty(masterVA: frame[0], slaveVA: frame[1])
    } else if number == sysPtySetForeground {
        result = vfsPtySetForeground(fd: Int(bitPattern: frame[0]), pid: Int(bitPattern: frame[1]))
    } else if number == sysSocketpair {
        result = vfsSocketpair(fdsVA: frame[0], flags: Int(bitPattern: frame[1]))
    } else if number == sysRandom {
        result = syscallRandom(buffer: frame[0], capacity: frame[1])
    } else {
        result = -38 // ENOSYS
    }

    frame[0] = UInt(bitPattern: result)
    signalDeliverToCurrentFrame(frame)
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

private func syscallLogRead(buffer ptr: UInt, capacity cap: UInt, maxCount: UInt) -> Int {
    if !klogCanExportRing(capabilities: processCurrentCaps()) { return -1 } // EPERM
    if cap == 0 || maxCount == 0 { return 0 }
    if cap > UInt(Int.max) || maxCount > UInt(Int.max) { return -22 }
    guard let dst = userWritableBuffer(ptr, cap) else { return -22 }
    return logFormatRecentTail(Int(maxCount), into: dst, capacity: Int(cap))
}

private func syscallLogStats(buffer ptr: UInt, capacity cap: UInt) -> Int {
    if !klogCanExportRing(capabilities: processCurrentCaps()) { return -1 } // EPERM
    if cap < UInt(logStatsSize) { return -22 }
    guard let dst = userWritableBuffer(ptr, UInt(logStatsSize)) else { return -22 }
    let raw = UnsafeMutableRawPointer(dst)
    raw.storeBytes(of: logRingStatsCapacity(), toByteOffset: 0, as: UInt64.self)
    raw.storeBytes(of: logRingStatsAvailable(), toByteOffset: 8, as: UInt64.self)
    raw.storeBytes(of: logRingStatsTotalWritten(), toByteOffset: 16, as: UInt64.self)
    raw.storeBytes(of: logRingStatsOverwritten(), toByteOffset: 24, as: UInt64.self)
    return 0
}

private func syscallRandom(buffer ptr: UInt, capacity cap: UInt) -> Int {
    if cap == 0 { return 0 }
    if cap > UInt(Int.max) { return -22 }
    guard let dst = userWritableBuffer(ptr, cap) else { return -22 }
    return virtioRngRead(dst, Int(cap))
}

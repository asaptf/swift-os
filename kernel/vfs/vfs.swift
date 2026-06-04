// vfs.swift — minimal VFS/file table for M5.

private let errBadFileDescriptor = -9
private let errNoEntry = -2
private let errInvalid = -22

private var file3Open = false
private var file3Offset = 0

private let helloPath: StaticString = "/hello.txt"
private let helloContent: StaticString = "M5 file: hello from VFS read()\n"

private func userCStringEquals(_ ptrValue: UInt, _ expected: StaticString) -> Bool {
    guard let ptr = UnsafePointer<UInt8>(bitPattern: ptrValue) else {
        return false
    }

    var matched = true
    expected.withUTF8Buffer { expectedBuffer in
        var i = 0
        while i < expectedBuffer.count {
            if ptr[i] != expectedBuffer[i] {
                matched = false
                return
            }
            i += 1
        }
        if ptr[expectedBuffer.count] != 0 {
            matched = false
        }
    }
    return matched
}

func vfsOpen(path: UInt, flags: UInt) -> Int {
    if flags != 0 {
        return errInvalid
    }
    if !userCStringEquals(path, helloPath) {
        return errNoEntry
    }

    file3Open = true
    file3Offset = 0
    return 3
}

func vfsRead(fd: Int, buffer: UInt, count: UInt) -> Int {
    if fd != 3 || !file3Open {
        return errBadFileDescriptor
    }
    guard let dst = UnsafeMutablePointer<UInt8>(bitPattern: buffer) else {
        return errInvalid
    }

    var copied = 0
    helloContent.withUTF8Buffer { source in
        while copied < Int(count) && file3Offset < source.count {
            dst[copied] = source[file3Offset]
            copied += 1
            file3Offset += 1
        }
    }

    return copied
}

func vfsWrite(fd: Int, buffer: UInt, count: UInt) -> Int {
    if fd != 1 && fd != 2 {
        return errBadFileDescriptor
    }
    guard let src = UnsafePointer<UInt8>(bitPattern: buffer) else {
        return errInvalid
    }

    var written: UInt = 0
    while written < count {
        uartPutc(src[Int(written)])
        written += 1
    }
    return Int(written)
}

func vfsClose(fd: Int) -> Int {
    if fd != 3 || !file3Open {
        return errBadFileDescriptor
    }

    file3Open = false
    file3Offset = 0
    return 0
}

func vfsLseek(fd: Int, offset: Int, whence: Int) -> Int {
    if fd != 3 || !file3Open {
        return errBadFileDescriptor
    }

    var base = 0
    if whence == 0 {
        base = 0
    } else if whence == 1 {
        base = file3Offset
    } else {
        helloContent.withUTF8Buffer { source in
            base = source.count
        }
    }

    let next = base + offset
    if next < 0 {
        return errInvalid
    }

    file3Offset = next
    return file3Offset
}

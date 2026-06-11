// SPDX-License-Identifier: Apache-2.0
import Foundation

@main
struct PageAllocatorRefcountLifecycleTest {
    static var failed = false

    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failed = true
        }
    }

    static func main() {
        let base: UInt = 0x5000_0000
        var bitmap = [UInt64](repeating: 0xFFFF_FFFF_FFFF_FFFF, count: 1)
        var refs = [UInt16](repeating: 0xFFFF, count: 3)

        bitmap.withUnsafeMutableBufferPointer { bitmapBuffer in
            refs.withUnsafeMutableBufferPointer { refBuffer in
                var allocator = PageAllocator(
                    base: base,
                    pageCount: 3,
                    bitmap: bitmapBuffer.baseAddress!,
                    refs: refBuffer.baseAddress!
                )

                guard let frame = allocator.allocate() else {
                    check(false, "initial allocation succeeds")
                    return
                }
                check(frame == base, "first frame allocated")
                check(allocator.freePages == 2, "one live frame consumes one free page")

                for _ in 0..<(Int(UInt16.max) + 17) {
                    allocator.ref(frame)
                }
                check(allocator.refcount(frame) == Int(UInt16.max),
                      "refcount saturates instead of wrapping")
                check(allocator.freePages == 2,
                      "extra references do not change allocation accounting")

                check(!allocator.unref(frame), "saturated frame is still shared after one drop")
                check(allocator.refcount(frame) == Int(UInt16.max) - 1,
                      "unref backs down from saturation by one")
                check(allocator.freePages == 2,
                      "non-final unref does not release the frame")

                var guardCount = 0
                while allocator.refcount(frame) > 1 {
                    check(!allocator.unref(frame), "intermediate unref keeps frame live")
                    guardCount += 1
                    if guardCount > Int(UInt16.max) {
                        check(false, "refcount drain made forward progress")
                        break
                    }
                }

                check(allocator.refcount(frame) == 1, "drain reaches one live reference")
                check(allocator.unref(frame), "last unref asks caller to raw-free")
                check(allocator.refcount(frame) == 0,
                      "last unref clears the visible refcount")
                check(allocator.freePages == 2,
                      "last unref does not raw-free behind the caller")

                let next = allocator.allocate()
                check(next == base + PageAllocator.pageSize,
                      "last-unreffed frame is not reused before raw free")
                if let next = next { allocator.free(next) }
                check(allocator.freePages == 2, "temporary allocation returned to pool")

                allocator.free(frame)
                check(allocator.freePages == 3, "raw free returns the last-dropped frame")
                check(allocator.refcount(frame) == 0, "raw free keeps refcount clear")
                check(allocator.allocate() == frame,
                      "raw-freed lower frame is immediately reusable")
            }
        }

        if failed {
            FileHandle.standardError.write(Data("page_allocator_refcount_lifecycle_test: FAILURES\n".utf8))
            exit(1)
        }
        print("PASS: page allocator refcount saturation and lifecycle test")
    }
}

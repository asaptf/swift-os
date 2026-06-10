// SPDX-License-Identifier: Apache-2.0
import Dispatch
import Foundation

@main
struct PageAllocatorTest {
    static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            print("FAIL: \(message)")
            fatalError()
        }
    }

    static func main() {
        var bitmap = [UInt64](repeating: 0xFFFF_FFFF_FFFF_FFFF, count: 2)
        var refs = [UInt16](repeating: 0xFFFF, count: 96)
        bitmap.withUnsafeMutableBufferPointer { buffer in
            refs.withUnsafeMutableBufferPointer { refBuffer in
                var allocator = PageAllocator(
                    base: 0x1000_0000,
                    pageCount: 96,
                    bitmap: buffer.baseAddress!,
                    refs: refBuffer.baseAddress!
                )

                expect(allocator.freePages == 96, "initial free count")
                expect(buffer[0] == 0 && buffer[1] == 0, "bitmap cleared on init")
                expect(refBuffer[0] == 0 && refBuffer[95] == 0, "refcounts cleared on init")

                allocator.reserve(base: 0x1000_0000, count: 2)
                expect(allocator.freePages == 94, "reserve consumes free pages")
                expect(allocator.refcount(0x1000_0000) == 1, "reserve sets refcount to one")

                let first = allocator.allocate()
                expect(first == 0x1000_2000, "first allocation skips reserved pages")
                expect(allocator.freePages == 93, "single allocation decrements free count")
                expect(allocator.refcount(first!) == 1, "allocation starts with refcount one")

                let run = allocator.allocateContiguous(4)
                expect(run == 0x1000_3000, "contiguous allocation returns next run")
                expect(allocator.freePages == 89, "contiguous allocation decrements free count")
                expect(allocator.refcount(run! + 3 * PageAllocator.pageSize) == 1, "contiguous allocation refs each frame")

                allocator.ref(first!)
                expect(allocator.refcount(first!) == 2, "ref increments a live frame")
                expect(!allocator.unref(first!), "unref of shared frame does not free")
                expect(allocator.refcount(first!) == 1, "unref decrements shared frame")
                expect(allocator.unref(first!), "last unref asks caller to free")
                expect(allocator.refcount(first!) == 0, "last unref leaves count zero until raw free")

                allocator.free(first!)
                expect(allocator.freePages == 90, "free restores one page")
                expect(allocator.refcount(first!) == 0, "free clears refcount")

                let reused = allocator.allocate()
                expect(reused == first, "allocator reuses freed lower frame")
                expect(allocator.refcount(reused!) == 1, "reused frame refcount reset")

                allocator.free(0x1000_0001)
                allocator.free(0x2000_0000)
                expect(allocator.freePages == 89, "invalid frees are ignored")

                expect(allocator.allocateContiguous(0) == nil, "zero-sized contiguous allocation rejected")
                expect(allocator.allocateContiguous(97) == nil, "oversized contiguous allocation rejected")
            }
        }

        var fragmentedBitmap = [UInt64](repeating: 0, count: 1)
        fragmentedBitmap.withUnsafeMutableBufferPointer { buffer in
            var allocator = PageAllocator(
                base: 0x2000_0000,
                pageCount: 8,
                bitmap: buffer.baseAddress!
            )

            allocator.reserve(base: 0x2000_1000, count: 2)
            allocator.reserve(base: 0x2000_1000, count: 2)
            expect(allocator.freePages == 6, "reserve is idempotent")

            let a = allocator.allocate()
            let b = allocator.allocate()
            let c = allocator.allocate()
            let d = allocator.allocate()
            expect(a == 0x2000_0000, "fragmentation setup first frame")
            expect(b == 0x2000_3000 && c == 0x2000_4000 && d == 0x2000_5000, "allocation skips reserved run")

            allocator.free(b!)
            expect(allocator.allocateContiguous(2) == 0x2000_6000, "contiguous scan skips fragmented holes")

            expect(allocator.allocate() == b, "hint rewinds to the lowest freed frame")
            expect(allocator.allocate() == nil, "allocator reports exhaustion")

            allocator.free(c!)
            allocator.free(c!)
            expect(allocator.freePages == 1, "double free ignored")
        }

        var noRefBitmap = [UInt64](repeating: 0, count: 1)
        noRefBitmap.withUnsafeMutableBufferPointer { buffer in
            var allocator = PageAllocator(
                base: 0x3000_0000,
                pageCount: 4,
                bitmap: buffer.baseAddress!
            )
            let a = allocator.allocate()!
            allocator.ref(a)
            expect(allocator.refcount(a) == 0, "nil ref table reports zero")
            expect(allocator.unref(a), "nil ref table treats unref as last drop")
        }

        final class LockedPageAllocator {
            private var allocator: PageAllocator
            private let lock = NSLock()

            init(base: UInt, pageCount: Int,
                 bitmap: UnsafeMutablePointer<UInt64>,
                 refs: UnsafeMutablePointer<UInt16>) {
                allocator = PageAllocator(base: base, pageCount: pageCount, bitmap: bitmap, refs: refs)
            }

            func allocate() -> UInt? {
                lock.lock()
                defer { lock.unlock() }
                return allocator.allocate()
            }

            func free(_ addr: UInt) {
                lock.lock()
                allocator.free(addr)
                lock.unlock()
            }

            func ref(_ addr: UInt) {
                lock.lock()
                allocator.ref(addr)
                lock.unlock()
            }

            func unref(_ addr: UInt) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return allocator.unref(addr)
            }

            func freePages() -> Int {
                lock.lock()
                defer { lock.unlock() }
                return allocator.freePages
            }
        }

        let stressPages = 256
        var stressBitmap = [UInt64](repeating: 0, count: (stressPages + 63) / 64)
        var stressRefs = [UInt16](repeating: 0, count: stressPages)
        stressBitmap.withUnsafeMutableBufferPointer { bitmap in
            stressRefs.withUnsafeMutableBufferPointer { refs in
                let locked = LockedPageAllocator(base: 0x4000_0000,
                                                 pageCount: stressPages,
                                                 bitmap: bitmap.baseAddress!,
                                                 refs: refs.baseAddress!)
                let liveLock = NSLock()
                var live = Set<UInt>()
                let workers = 8
                let iterations = 4_000
                DispatchQueue.concurrentPerform(iterations: workers) { worker in
                    var local: [UInt] = []
                    local.reserveCapacity(12)
                    for step in 0..<iterations {
                        if local.count < 12 && ((step + worker) & 3) != 0 {
                            if let addr = locked.allocate() {
                                liveLock.lock()
                                let inserted = live.insert(addr).inserted
                                liveLock.unlock()
                                expect(inserted, "concurrent allocator handed out a duplicate live frame")
                                if ((step + worker) % 11) == 0 {
                                    locked.ref(addr)
                                    expect(!locked.unref(addr), "shared concurrent ref should not raw-free")
                                }
                                local.append(addr)
                            }
                        } else if !local.isEmpty {
                            let idx = (step + worker) % local.count
                            let addr = local.remove(at: idx)
                            liveLock.lock()
                            let removed = live.remove(addr) != nil
                            liveLock.unlock()
                            expect(removed, "concurrent allocator freed an unknown frame")
                            locked.free(addr)
                        }
                    }
                    for addr in local {
                        liveLock.lock()
                        let removed = live.remove(addr) != nil
                        liveLock.unlock()
                        expect(removed, "concurrent allocator cleanup saw an unknown frame")
                        locked.free(addr)
                    }
                }
                liveLock.lock()
                let liveEmpty = live.isEmpty
                liveLock.unlock()
                expect(liveEmpty, "concurrent allocator stress leaked live tracking entries")
                expect(locked.freePages() == stressPages, "concurrent allocator stress returned every page")
            }
        }

        print("PASS: page allocator unit + adversarial + concurrent stress tests")
    }
}

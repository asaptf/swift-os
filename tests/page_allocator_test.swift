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
        bitmap.withUnsafeMutableBufferPointer { buffer in
            var allocator = PageAllocator(
                base: 0x1000_0000,
                pageCount: 96,
                bitmap: buffer.baseAddress!
            )

            expect(allocator.freePages == 96, "initial free count")
            expect(buffer[0] == 0 && buffer[1] == 0, "bitmap cleared on init")

            allocator.reserve(base: 0x1000_0000, count: 2)
            expect(allocator.freePages == 94, "reserve consumes free pages")

            let first = allocator.allocate()
            expect(first == 0x1000_2000, "first allocation skips reserved pages")
            expect(allocator.freePages == 93, "single allocation decrements free count")

            let run = allocator.allocateContiguous(4)
            expect(run == 0x1000_3000, "contiguous allocation returns next run")
            expect(allocator.freePages == 89, "contiguous allocation decrements free count")

            allocator.free(first!)
            expect(allocator.freePages == 90, "free restores one page")

            let reused = allocator.allocate()
            expect(reused == first, "allocator reuses freed lower frame")

            allocator.free(0x1000_0001)
            allocator.free(0x2000_0000)
            expect(allocator.freePages == 89, "invalid frees are ignored")

            expect(allocator.allocateContiguous(0) == nil, "zero-sized contiguous allocation rejected")
            expect(allocator.allocateContiguous(97) == nil, "oversized contiguous allocation rejected")
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

        print("PASS: page allocator unit + adversarial tests")
    }
}

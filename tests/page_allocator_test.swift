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

        print("PASS: page allocator unit tests")
    }
}

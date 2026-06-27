// SPDX-License-Identifier: Apache-2.0
// fb.swift — linear-framebuffer text console.
//
// The UEFI loader hands the kernel a Graphics Output Protocol framebuffer
// (base, dimensions, stride) discovered before ExitBootServices. This renders
// the kernel's serial output onto that framebuffer with the classic IBM PC /
// VGA 8x16 ROM font (the 80x25 text-mode glyph cell), so the boot log reads
// like a PC console on a QEMU display window (-device ramfb), not only on the
// serial line. 32-bpp, white-on-black; the pixel format (RGBX vs BGRX) does
// not matter for those two colours.
//
// The framebuffer lives in normal cacheable RAM (it sits in the kernel's 1 GiB
// RAM block), and QEMU's ramfb scans RAM directly, so every write is cleaned to
// the point of coherency or the display would show stale pixels.
//
// A reverse-video block cursor blinks at the text position (fb_cursor_blink,
// driven from the timer tick). A shadow buffer of the on-screen characters lets
// the cursor lift off whatever glyph it covers, and fb_putc honours backspace as
// a non-destructive cursor-left, so the tty line editor can move within a line.
//
// Swift rewrite of the former fb.c: a self-contained leaf module (no PMM, no
// page tables). The framebuffer is identity-mapped RAM (the GOP buffer), reached
// through UnsafeMutableRawPointer with explicit raw stores (the volatile writes
// of the C original); the only asm is the dc_cvac / dsb_sy cache maintenance
// from the io.h bridge.

private let GLYPH_W = 8
private let GLYPH_H = 16               // IBM PC / VGA text-mode glyph cell (8 wide, 16 tall)

// Global layout note (kernel builds with `-mattr=+strict-align`, which faults on
// a misaligned multi-byte access): the linker may reorder private globals, so
// source order alone cannot guarantee that adjacent 32-bit cursor/layout globals
// land on an 8-byte pair boundary. Keep the hot framebuffer state in machine
// words; then any scalar or fused store the optimizer emits is naturally aligned.
private var g_fb: UInt = 0             // PA of the framebuffer (0 = disabled)
private var g_fb_base: UInt64 = 0, g_fb_size: UInt64 = 0   // for the PMM to reserve the region
private var g_cx: UInt = 0, g_cy: UInt = 0   // text cursor cell (column, row)
private var g_w: UInt = 0, g_h: UInt = 0, g_stride: UInt = 0 // pixels; stride = pixels per scanline
private var g_cols: UInt = 0, g_rows: UInt = 0

private let FG: UInt32 = 0xFFFFFFFF
private let BG: UInt32 = 0x00000000

// 16-colour ANSI/VGA palette, stored as the framebuffer's native 32-bpp word.
// QEMU's ramfb / edk2 GOP on aarch64 `virt` is XRGB8888 (little-endian memory
// order B,G,R,X), so a 0x00RRGGBB literal lands in the right channels — white
// (0xFFFFFF) and black (0) are format-agnostic, the colours are verified by a
// framebuffer screendump. Index 7 ("white"/lightgray, the default foreground)
// is pure white so the boot banner and shell stay white-on-black exactly as
// before; bold brightens a 0–7 index into its 8–15 twin (the linux console's
// bright-on-bold convention that ncurses relies on for the A_BOLD colours).
private let PALETTE: InlineArray<16, UInt32> = [
    0x000000,   // 0 black
    0xAA0000,   // 1 red
    0x00AA00,   // 2 green
    0xAA5500,   // 3 brown/yellow
    0x0000AA,   // 4 blue
    0xAA00AA,   // 5 magenta
    0x00AAAA,   // 6 cyan
    0xFFFFFF,   // 7 white (default fg; pure white keeps the boot banner white)
    0x555555,   // 8 bright black (gray)
    0xFF5555,   // 9 bright red
    0x55FF55,   // 10 bright green
    0xFFFF55,   // 11 bright yellow
    0x5555FF,   // 12 bright blue
    0xFF55FF,   // 13 bright magenta
    0x55FFFF,   // 14 bright cyan
    0xFFFFFF,   // 15 bright white
]

// Current SGR (Select Graphic Rendition) state, applied to glyphs as they are
// drawn. fg/bg are palette indices 0–7; bold brightens the foreground; reverse
// swaps fg/bg (mc's menu/selection bars). DEFAULT_ATTR packs the reset state
// (fg 7 = white, bg 0 = black) into the per-cell attribute byte below.
private let DEFAULT_ATTR: UInt8 = 0x07     // (bg 0 << 4) | (fg 7)
private var g_sgr_fg: UInt8 = 7
private var g_sgr_bg: UInt8 = 0
private var g_sgr_bold = false
private var g_sgr_reverse = false

// Effective (fg,bg) palette indices for the current SGR state, after applying
// bold (brightens fg) and reverse (swaps fg/bg). Packed as bg<<4 | fg.
@inline(__always)
private func sgrAttr() -> UInt8 {
    var fg = g_sgr_fg
    var bg = g_sgr_bg
    if g_sgr_bold { fg |= 0x08 }
    if g_sgr_reverse { let t = fg; fg = bg; bg = t }
    return (bg << 4) | (fg & 0x0F)
}

@inline(__always) private func attrFg(_ a: UInt8) -> UInt32 { PALETTE[Int(a & 0x0F)] }
@inline(__always) private func attrBg(_ a: UInt8) -> UInt32 { PALETTE[Int((a >> 4) & 0x0F)] }

// Shadow text buffer: the glyph drawn in every cell, so the blinking cursor can
// restore whatever character it sits on rather than blanking it. Bounded so the
// buffer is a fixed BSS array; larger framebuffers just use the top-left region.
// An `InlineArray` (not `[UInt8]`), like font8x16 above: it is written from
// fb_init/fb_putc during the early boot banner, before the kernel heap is set up,
// so it must not be heap-backed. Count is MAX_ROWS * MAX_COLS = 128 * 256 (an
// InlineArray length must be a literal, so it cannot be spelled as that product).
// Initialised to ' ' so the cells start blank: this materialises as a static,
// space-filled .data blob, exactly the state the C original reached by clearing
// the array in fb_init. We deliberately do *not* re-clear it in a fb_init loop —
// fb_init runs once per boot, and a byte-fill loop over this 1-byte-aligned array
// vectorises to a 16-byte `str q0`, which faults under +strict-align because the
// array is only 8-aligned. The static initial state is equivalent and fault-free.
private let MAX_COLS = 256
private let MAX_ROWS = 128
private var g_cells: InlineArray<32768, UInt8> = .init(repeating: UInt8(ascii: " "))

// Parallel shadow of the colour attribute (bg<<4 | fg palette index) drawn in
// every cell, so the cursor lift, line erase and scroll repaint each glyph in
// its own colours rather than the default white-on-black. Same fixed-BSS
// InlineArray discipline as g_cells (heap-free, statically initialised to the
// reset attribute — no fb_init fill loop, which would fault under +strict-align).
private var g_cell_attr: InlineArray<32768, UInt8> = .init(repeating: 0x07)  // DEFAULT_ATTR

// Reverse-video block cursor, blinked from the timer tick. g_cur_* records where
// the cursor is currently painted so it can be lifted when it moves or blinks off.
private var g_cur_col: UInt = 0, g_cur_row: UInt = 0
private var g_blink_ctr: UInt = 0
private var g_gpu_flush_ctr: UInt = 0   // throttles the timer-driven virtio-gpu scanout flush
private var g_blink_on = true          // desired phase: true = show cursor, false = hide
private var g_cur_drawn = false        // is an inverted cell currently on screen?

// font8x16 — the classic IBM PC / VGA 8x16 ROM text font (public domain).
// 16 rows per glyph; bit 7 (0x80) is the leftmost pixel (VGA bit order). Stored
// flat as 128 glyphs × 16 rows; rows 0x00..0x1F and 0x7F are blank, like the
// sparse C initializer. An `InlineArray` (not `[UInt8]`) so the bytes are a fixed,
// statically-allocated blob — the exact equivalent of C's `static const uint8_t
// font8x16[128][16]`. A heap-backed Swift `Array` would lazily allocate on first
// glyph render, but rendering begins while the kernel logs its banner, *before*
// `swiftos_heap_init()` runs in `kernel_main` — that early allocation, then the
// heap re-init that resets the bump cursor, would alias this storage onto later
// kernel allocations and corrupt them. `InlineArray` needs no heap. (do not
// change back to `[UInt8]`.)
private let font8x16: InlineArray<2048, UInt8> = [
    // 0x00..0x1F — control range, blank (32 glyphs × 16 rows)
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00, // 0x20 space
    0x00,0x00,0x18,0x3C,0x3C,0x3C,0x18,0x18,0x18,0x00,0x18,0x18,0x00,0x00,0x00,0x00, // 0x21 !
    0x00,0x66,0x66,0x66,0x24,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00, // 0x22 "
    0x00,0x00,0x00,0x6C,0x6C,0xFE,0x6C,0x6C,0x6C,0xFE,0x6C,0x6C,0x00,0x00,0x00,0x00, // 0x23 #
    0x18,0x18,0x7C,0xC6,0xC2,0xC0,0x7C,0x06,0x06,0x86,0xC6,0x7C,0x18,0x18,0x00,0x00, // 0x24 $
    0x00,0x00,0x00,0x00,0xC2,0xC6,0x0C,0x18,0x30,0x60,0xC6,0x86,0x00,0x00,0x00,0x00, // 0x25 %
    0x00,0x00,0x38,0x6C,0x6C,0x38,0x76,0xDC,0xCC,0xCC,0xCC,0x76,0x00,0x00,0x00,0x00, // 0x26 &
    0x00,0x30,0x30,0x30,0x60,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00, // 0x27 '
    0x00,0x00,0x0C,0x18,0x30,0x30,0x30,0x30,0x30,0x30,0x18,0x0C,0x00,0x00,0x00,0x00, // 0x28 (
    0x00,0x00,0x30,0x18,0x0C,0x0C,0x0C,0x0C,0x0C,0x0C,0x18,0x30,0x00,0x00,0x00,0x00, // 0x29 )
    0x00,0x00,0x00,0x00,0x00,0x66,0x3C,0xFF,0x3C,0x66,0x00,0x00,0x00,0x00,0x00,0x00, // 0x2A *
    0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x7E,0x18,0x18,0x00,0x00,0x00,0x00,0x00,0x00, // 0x2B +
    0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x18,0x30,0x00,0x00, // 0x2C ,
    0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xFE,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00, // 0x2D -
    0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x00,0x00,0x00,0x00, // 0x2E .
    0x00,0x00,0x00,0x00,0x02,0x06,0x0C,0x18,0x30,0x60,0xC0,0x80,0x00,0x00,0x00,0x00, // 0x2F /
    0x00,0x00,0x7C,0xC6,0xCE,0xDE,0xF6,0xE6,0xC6,0xC6,0xC6,0x7C,0x00,0x00,0x00,0x00, // 0x30 0
    0x00,0x00,0x18,0x38,0x78,0x18,0x18,0x18,0x18,0x18,0x18,0x7E,0x00,0x00,0x00,0x00, // 0x31 1
    0x00,0x00,0x7C,0xC6,0x06,0x0C,0x18,0x30,0x60,0xC0,0xC6,0xFE,0x00,0x00,0x00,0x00, // 0x32 2
    0x00,0x00,0x7C,0xC6,0x06,0x06,0x3C,0x06,0x06,0x06,0xC6,0x7C,0x00,0x00,0x00,0x00, // 0x33 3
    0x00,0x00,0x0C,0x1C,0x3C,0x6C,0xCC,0xFE,0x0C,0x0C,0x0C,0x1E,0x00,0x00,0x00,0x00, // 0x34 4
    0x00,0x00,0xFE,0xC0,0xC0,0xC0,0xFC,0x06,0x06,0x06,0xC6,0x7C,0x00,0x00,0x00,0x00, // 0x35 5
    0x00,0x00,0x38,0x60,0xC0,0xC0,0xFC,0xC6,0xC6,0xC6,0xC6,0x7C,0x00,0x00,0x00,0x00, // 0x36 6
    0x00,0x00,0xFE,0xC6,0x06,0x06,0x0C,0x18,0x30,0x30,0x30,0x30,0x00,0x00,0x00,0x00, // 0x37 7
    0x00,0x00,0x7C,0xC6,0xC6,0xC6,0x7C,0xC6,0xC6,0xC6,0xC6,0x7C,0x00,0x00,0x00,0x00, // 0x38 8
    0x00,0x00,0x7C,0xC6,0xC6,0xC6,0x7E,0x06,0x06,0x06,0x0C,0x78,0x00,0x00,0x00,0x00, // 0x39 9
    0x00,0x00,0x00,0x00,0x18,0x18,0x00,0x00,0x00,0x18,0x18,0x00,0x00,0x00,0x00,0x00, // 0x3A :
    0x00,0x00,0x00,0x00,0x18,0x18,0x00,0x00,0x00,0x18,0x18,0x30,0x00,0x00,0x00,0x00, // 0x3B ;
    0x00,0x00,0x00,0x06,0x0C,0x18,0x30,0x60,0x30,0x18,0x0C,0x06,0x00,0x00,0x00,0x00, // 0x3C <
    0x00,0x00,0x00,0x00,0x00,0x7E,0x00,0x00,0x7E,0x00,0x00,0x00,0x00,0x00,0x00,0x00, // 0x3D =
    0x00,0x00,0x00,0x60,0x30,0x18,0x0C,0x06,0x0C,0x18,0x30,0x60,0x00,0x00,0x00,0x00, // 0x3E >
    0x00,0x00,0x7C,0xC6,0xC6,0x0C,0x18,0x18,0x18,0x00,0x18,0x18,0x00,0x00,0x00,0x00, // 0x3F ?
    0x00,0x00,0x00,0x7C,0xC6,0xC6,0xDE,0xDE,0xDE,0xDC,0xC0,0x7C,0x00,0x00,0x00,0x00, // 0x40 @
    0x00,0x00,0x10,0x38,0x6C,0xC6,0xC6,0xFE,0xC6,0xC6,0xC6,0xC6,0x00,0x00,0x00,0x00, // 0x41 A
    0x00,0x00,0xFC,0x66,0x66,0x66,0x7C,0x66,0x66,0x66,0x66,0xFC,0x00,0x00,0x00,0x00, // 0x42 B
    0x00,0x00,0x3C,0x66,0xC2,0xC0,0xC0,0xC0,0xC0,0xC2,0x66,0x3C,0x00,0x00,0x00,0x00, // 0x43 C
    0x00,0x00,0xF8,0x6C,0x66,0x66,0x66,0x66,0x66,0x66,0x6C,0xF8,0x00,0x00,0x00,0x00, // 0x44 D
    0x00,0x00,0xFE,0x66,0x62,0x68,0x78,0x68,0x60,0x62,0x66,0xFE,0x00,0x00,0x00,0x00, // 0x45 E
    0x00,0x00,0xFE,0x66,0x62,0x68,0x78,0x68,0x60,0x60,0x60,0xF0,0x00,0x00,0x00,0x00, // 0x46 F
    0x00,0x00,0x3C,0x66,0xC2,0xC0,0xC0,0xDE,0xC6,0xC6,0x66,0x3A,0x00,0x00,0x00,0x00, // 0x47 G
    0x00,0x00,0xC6,0xC6,0xC6,0xC6,0xFE,0xC6,0xC6,0xC6,0xC6,0xC6,0x00,0x00,0x00,0x00, // 0x48 H
    0x00,0x00,0x3C,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x3C,0x00,0x00,0x00,0x00, // 0x49 I
    0x00,0x00,0x1E,0x0C,0x0C,0x0C,0x0C,0x0C,0xCC,0xCC,0xCC,0x78,0x00,0x00,0x00,0x00, // 0x4A J
    0x00,0x00,0xE6,0x66,0x66,0x6C,0x78,0x78,0x6C,0x66,0x66,0xE6,0x00,0x00,0x00,0x00, // 0x4B K
    0x00,0x00,0xF0,0x60,0x60,0x60,0x60,0x60,0x60,0x62,0x66,0xFE,0x00,0x00,0x00,0x00, // 0x4C L
    0x00,0x00,0xC6,0xEE,0xFE,0xFE,0xD6,0xC6,0xC6,0xC6,0xC6,0xC6,0x00,0x00,0x00,0x00, // 0x4D M
    0x00,0x00,0xC6,0xE6,0xF6,0xFE,0xDE,0xCE,0xC6,0xC6,0xC6,0xC6,0x00,0x00,0x00,0x00, // 0x4E N
    0x00,0x00,0x7C,0xC6,0xC6,0xC6,0xC6,0xC6,0xC6,0xC6,0xC6,0x7C,0x00,0x00,0x00,0x00, // 0x4F O
    0x00,0x00,0xFC,0x66,0x66,0x66,0x7C,0x60,0x60,0x60,0x60,0xF0,0x00,0x00,0x00,0x00, // 0x50 P
    0x00,0x00,0x7C,0xC6,0xC6,0xC6,0xC6,0xC6,0xC6,0xD6,0xDE,0x7C,0x0C,0x0E,0x00,0x00, // 0x51 Q
    0x00,0x00,0xFC,0x66,0x66,0x66,0x7C,0x6C,0x66,0x66,0x66,0xE6,0x00,0x00,0x00,0x00, // 0x52 R
    0x00,0x00,0x7C,0xC6,0xC6,0x60,0x38,0x0C,0x06,0xC6,0xC6,0x7C,0x00,0x00,0x00,0x00, // 0x53 S
    0x00,0x00,0x7E,0x7E,0x5A,0x18,0x18,0x18,0x18,0x18,0x18,0x3C,0x00,0x00,0x00,0x00, // 0x54 T
    0x00,0x00,0xC6,0xC6,0xC6,0xC6,0xC6,0xC6,0xC6,0xC6,0xC6,0x7C,0x00,0x00,0x00,0x00, // 0x55 U
    0x00,0x00,0xC6,0xC6,0xC6,0xC6,0xC6,0xC6,0xC6,0x6C,0x38,0x10,0x00,0x00,0x00,0x00, // 0x56 V
    0x00,0x00,0xC6,0xC6,0xC6,0xC6,0xD6,0xD6,0xD6,0xFE,0xEE,0x6C,0x00,0x00,0x00,0x00, // 0x57 W
    0x00,0x00,0xC6,0xC6,0x6C,0x7C,0x38,0x38,0x7C,0x6C,0xC6,0xC6,0x00,0x00,0x00,0x00, // 0x58 X
    0x00,0x00,0x66,0x66,0x66,0x66,0x3C,0x18,0x18,0x18,0x18,0x3C,0x00,0x00,0x00,0x00, // 0x59 Y
    0x00,0x00,0xFE,0xC6,0x86,0x0C,0x18,0x30,0x60,0xC2,0xC6,0xFE,0x00,0x00,0x00,0x00, // 0x5A Z
    0x00,0x00,0x3C,0x30,0x30,0x30,0x30,0x30,0x30,0x30,0x30,0x3C,0x00,0x00,0x00,0x00, // 0x5B [
    0x00,0x00,0x00,0x80,0xC0,0xE0,0x70,0x38,0x1C,0x0E,0x06,0x02,0x00,0x00,0x00,0x00, // 0x5C backslash
    0x00,0x00,0x3C,0x0C,0x0C,0x0C,0x0C,0x0C,0x0C,0x0C,0x0C,0x3C,0x00,0x00,0x00,0x00, // 0x5D ]
    0x10,0x38,0x6C,0xC6,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00, // 0x5E ^
    0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xFF,0x00,0x00, // 0x5F _
    0x00,0x30,0x18,0x0C,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00, // 0x60 `
    0x00,0x00,0x00,0x00,0x00,0x78,0x0C,0x7C,0xCC,0xCC,0xCC,0x76,0x00,0x00,0x00,0x00, // 0x61 a
    0x00,0x00,0xE0,0x60,0x60,0x78,0x6C,0x66,0x66,0x66,0x66,0x7C,0x00,0x00,0x00,0x00, // 0x62 b
    0x00,0x00,0x00,0x00,0x00,0x7C,0xC6,0xC0,0xC0,0xC0,0xC6,0x7C,0x00,0x00,0x00,0x00, // 0x63 c
    0x00,0x00,0x1C,0x0C,0x0C,0x3C,0x6C,0xCC,0xCC,0xCC,0xCC,0x76,0x00,0x00,0x00,0x00, // 0x64 d
    0x00,0x00,0x00,0x00,0x00,0x7C,0xC6,0xFE,0xC0,0xC0,0xC6,0x7C,0x00,0x00,0x00,0x00, // 0x65 e
    0x00,0x00,0x38,0x6C,0x64,0x60,0xF0,0x60,0x60,0x60,0x60,0xF0,0x00,0x00,0x00,0x00, // 0x66 f
    0x00,0x00,0x00,0x00,0x00,0x76,0xCC,0xCC,0xCC,0xCC,0xCC,0x7C,0x0C,0xCC,0x78,0x00, // 0x67 g
    0x00,0x00,0xE0,0x60,0x60,0x6C,0x76,0x66,0x66,0x66,0x66,0xE6,0x00,0x00,0x00,0x00, // 0x68 h
    0x00,0x00,0x18,0x18,0x00,0x38,0x18,0x18,0x18,0x18,0x18,0x3C,0x00,0x00,0x00,0x00, // 0x69 i
    0x00,0x00,0x06,0x06,0x00,0x0E,0x06,0x06,0x06,0x06,0x06,0x06,0x66,0x66,0x3C,0x00, // 0x6A j
    0x00,0x00,0xE0,0x60,0x60,0x66,0x6C,0x78,0x78,0x6C,0x66,0xE6,0x00,0x00,0x00,0x00, // 0x6B k
    0x00,0x00,0x38,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x3C,0x00,0x00,0x00,0x00, // 0x6C l
    0x00,0x00,0x00,0x00,0x00,0xEC,0xFE,0xD6,0xD6,0xD6,0xD6,0xC6,0x00,0x00,0x00,0x00, // 0x6D m
    0x00,0x00,0x00,0x00,0x00,0xDC,0x66,0x66,0x66,0x66,0x66,0x66,0x00,0x00,0x00,0x00, // 0x6E n
    0x00,0x00,0x00,0x00,0x00,0x7C,0xC6,0xC6,0xC6,0xC6,0xC6,0x7C,0x00,0x00,0x00,0x00, // 0x6F o
    0x00,0x00,0x00,0x00,0x00,0xDC,0x66,0x66,0x66,0x66,0x66,0x7C,0x60,0x60,0xF0,0x00, // 0x70 p
    0x00,0x00,0x00,0x00,0x00,0x76,0xCC,0xCC,0xCC,0xCC,0xCC,0x7C,0x0C,0x0C,0x1E,0x00, // 0x71 q
    0x00,0x00,0x00,0x00,0x00,0xDC,0x76,0x66,0x60,0x60,0x60,0xF0,0x00,0x00,0x00,0x00, // 0x72 r
    0x00,0x00,0x00,0x00,0x00,0x7C,0xC6,0x60,0x38,0x0C,0xC6,0x7C,0x00,0x00,0x00,0x00, // 0x73 s
    0x00,0x00,0x10,0x30,0x30,0xFC,0x30,0x30,0x30,0x30,0x36,0x1C,0x00,0x00,0x00,0x00, // 0x74 t
    0x00,0x00,0x00,0x00,0x00,0xCC,0xCC,0xCC,0xCC,0xCC,0xCC,0x76,0x00,0x00,0x00,0x00, // 0x75 u
    0x00,0x00,0x00,0x00,0x00,0xC6,0xC6,0xC6,0xC6,0x6C,0x38,0x10,0x00,0x00,0x00,0x00, // 0x76 v
    0x00,0x00,0x00,0x00,0x00,0xC6,0xC6,0xD6,0xD6,0xD6,0xFE,0x6C,0x00,0x00,0x00,0x00, // 0x77 w
    0x00,0x00,0x00,0x00,0x00,0xC6,0x6C,0x38,0x38,0x38,0x6C,0xC6,0x00,0x00,0x00,0x00, // 0x78 x
    0x00,0x00,0x00,0x00,0x00,0xC6,0xC6,0xC6,0xC6,0xC6,0xC6,0x7E,0x06,0x0C,0xF8,0x00, // 0x79 y
    0x00,0x00,0x00,0x00,0x00,0xFE,0xCC,0x18,0x30,0x60,0xC6,0xFE,0x00,0x00,0x00,0x00, // 0x7A z
    0x00,0x00,0x0E,0x18,0x18,0x18,0x70,0x18,0x18,0x18,0x18,0x0E,0x00,0x00,0x00,0x00, // 0x7B {
    0x00,0x00,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x00,0x00,0x00,0x00, // 0x7C |
    0x00,0x00,0x70,0x18,0x18,0x18,0x0E,0x18,0x18,0x18,0x18,0x70,0x00,0x00,0x00,0x00, // 0x7D }
    0x00,0x00,0x76,0xDC,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00, // 0x7E ~
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,                                                // 0x7F blank
]

// --- framebuffer pixel access ----------------------------------------------
// The framebuffer is identity-mapped RAM; writes use explicit raw stores (the
// volatile pixel writes of the C original) so the optimizer cannot drop them.
@inline(__always)
private func fbStorePixel(_ wordIndex: UInt64, _ value: UInt32) {
    let p = UnsafeMutableRawPointer(bitPattern: g_fb + UInt(wordIndex * 4))!
    p.storeBytes(of: value, as: UInt32.self)
}

@inline(__always)
private func fbLoadPixel(_ wordIndex: UInt64) -> UInt32 {
    let p = UnsafeRawPointer(bitPattern: g_fb + UInt(wordIndex * 4))!
    return p.load(as: UInt32.self)
}

// Clean [addr, addr+len) from the data cache to the point of coherency, so the
// ramfb scanout (which reads RAM) sees the pixels we just wrote.
private func fb_clean(_ addr: UInt64, _ len: UInt64) {
    let line: UInt64 = 64
    var a = addr & ~(line - 1)
    while a < addr + len {
        dc_cvac(UInt(a))
        a += line
    }
    dsb_sy()
}

@_cdecl("fb_init")
func fb_init(_ base: UInt64, _ width: UInt32, _ height: UInt32, _ stride_px: UInt32) {
    if base == 0 || width == 0 || height == 0 {
        g_fb = 0
        return
    }
    g_fb = UInt(base)
    g_w = UInt(width)
    g_h = UInt(height)
    g_stride = UInt(stride_px)
    g_cols = g_w / UInt(GLYPH_W)
    g_rows = g_h / UInt(GLYPH_H)
    if g_cols > UInt(MAX_COLS) { g_cols = UInt(MAX_COLS) }  // text area is the top-left region
    if g_rows > UInt(MAX_ROWS) { g_rows = UInt(MAX_ROWS) }
    g_cx = 0
    g_cy = 0
    g_fb_base = base
    g_fb_size = UInt64(g_stride) * UInt64(g_h) * 4
    var i: UInt64 = 0
    let total = UInt64(g_stride) * UInt64(g_h)
    while i < total {
        fbStorePixel(i, 0x00000000)
        i += 1
    }
    // g_cells already starts space-filled (see its declaration); fb_init runs
    // once per boot, so no re-clear loop is needed — and adding one would emit a
    // misaligned 16-byte vector store that faults under +strict-align.
    g_cur_drawn = false
    fb_clean(g_fb_base, g_fb_size)
}

@_cdecl("fb_available")
func fb_available() -> Int32 { g_fb != 0 ? 1 : 0 }

@_cdecl("fb_phys_base")
func fb_phys_base() -> UInt64 { g_fb_base }

@_cdecl("fb_phys_size")
func fb_phys_size() -> UInt64 { g_fb_size }

// Render a glyph at (cx,cy) with explicit foreground/background colours: lit
// font pixels take `fg`, the cell background `bg`. The text cursor draws its
// reverse-video block by passing the cell's colours swapped.
private func fb_render(_ c: UInt8, _ cx: UInt, _ cy: UInt, _ fg: UInt32, _ bg: UInt32) {
    let glyph = Int(c & 0x7F) * GLYPH_H
    let px0 = UInt64(cx) * UInt64(GLYPH_W)
    let py0 = UInt64(cy) * UInt64(GLYPH_H)
    for row in 0..<GLYPH_H {
        let bits = font8x16[glyph + row]   // VGA bit order: bit 7 is the leftmost pixel
        let lineBase = (py0 + UInt64(row)) * UInt64(g_stride) + px0
        for col in 0..<GLYPH_W {
            fbStorePixel(lineBase + UInt64(col), ((bits >> (7 - col)) & 1) != 0 ? fg : bg)
        }
        fb_clean(g_fb_base + lineBase * 4, UInt64(GLYPH_W) * 4)
    }
}

// Draw a printable glyph at the cursor cell in the current SGR colours, and
// remember both the glyph and its colour attribute in the shadow buffers.
private func fb_draw_glyph(_ c: UInt8, _ cx: UInt, _ cy: UInt) {
    let attr = sgrAttr()
    if cx < UInt(MAX_COLS) && cy < UInt(MAX_ROWS) {
        g_cells[Int(cy) * MAX_COLS + Int(cx)] = c
        g_cell_attr[Int(cy) * MAX_COLS + Int(cx)] = attr
    }
    fb_render(c, cx, cy, attrFg(attr), attrBg(attr))
}

// Repaint a cell from the shadow buffers (used to lift the cursor off it),
// restoring both its glyph and its colour.
private func fb_restore_cell(_ cx: UInt, _ cy: UInt) {
    let inBounds = cx < UInt(MAX_COLS) && cy < UInt(MAX_ROWS)
    var c = inBounds ? g_cells[Int(cy) * MAX_COLS + Int(cx)] : UInt8(ascii: " ")
    if c < 0x20 { c = UInt8(ascii: " ") }
    let attr = inBounds ? g_cell_attr[Int(cy) * MAX_COLS + Int(cx)] : DEFAULT_ATTR
    fb_render(c, cx, cy, attrFg(attr), attrBg(attr))
}

private func fb_scroll() {
    let row_px = UInt64(GLYPH_H) * UInt64(g_stride)       // pixels in one text row
    let move = UInt64(g_h - UInt(GLYPH_H)) * UInt64(g_stride) // pixels to shift up
    var i: UInt64 = 0
    while i < move {
        fbStorePixel(i, fbLoadPixel(i + row_px))
        i += 1
    }
    // New bottom row clears to the current background (background-colour erase),
    // so a scroll inside a coloured screen keeps that colour rather than black.
    let newAttr = sgrAttr()
    let newBg = attrBg(newAttr)
    let bottom = UInt64(g_h) * UInt64(g_stride)
    i = move
    while i < bottom {
        fbStorePixel(i, newBg)
        i += 1
    }
    // Mirror the scroll in both shadow buffers so the cursor restores correctly.
    var r: UInt = 1
    while r < g_rows {
        for c in 0..<Int(g_cols) {
            g_cells[Int(r - 1) * MAX_COLS + c] = g_cells[Int(r) * MAX_COLS + c]
            g_cell_attr[Int(r - 1) * MAX_COLS + c] = g_cell_attr[Int(r) * MAX_COLS + c]
        }
        r += 1
    }
    for c in 0..<Int(g_cols) {
        g_cells[Int(g_rows - 1) * MAX_COLS + c] = UInt8(ascii: " ")
        g_cell_attr[Int(g_rows - 1) * MAX_COLS + c] = newAttr
    }
    g_cur_drawn = false  // its old painted cell scrolled away
    fb_clean(g_fb_base, g_fb_size)
}

// ---- ANSI / VT100 escape-sequence interpreter -----------------------------
//
// fb_putc mirrors every byte written to the console (uartPutc), so a full-screen
// program like vi drives it with VT100 control sequences, not just printable
// text. We parse the subset those programs use: cursor positioning (CUP),
// relative cursor moves (CUU/CUD/CUF/CUB, CHA, VPA), erase-in-display (ED) and
// erase-in-line (EL), SGR colour/bold/reverse (so mc draws its blue panels), and
// the alternate-screen private modes. Anything unrecognised is swallowed, never
// printed, so a stray escape can't turn into garbage glyphs. A real serial
// terminal still sees the raw bytes via the UART unchanged.

private let ST_NORMAL: Int32 = 0
private let ST_ESC: Int32 = 1
private let ST_CSI: Int32 = 2
private let ST_ESC_INTER: Int32 = 3

private let MAX_PARAMS = 8
private var g_state: Int32 = ST_NORMAL
private var g_params: InlineArray<8, Int32> = .init(repeating: 0)  // MAX_PARAMS; heap-free, see g_cells
private var g_pidx: Int = 0         // index of the parameter currently being collected
private var g_any: Bool = false     // any parameter char (digit or ';') seen
private var g_csi_private: Bool = false   // a '?' prefixed the parameters (DEC private mode)

// CSI parameter i, with `dflt` substituted when it is absent or zero. Cursor
// commands default to 1; erase modes default to 0 (and 0 is a real mode).
private func csi_param(_ i: Int, _ dflt: Int32) -> Int32 {
    let count = g_any ? (g_pidx + 1) : 0
    let v = (i < count) ? g_params[i] : 0
    return v == 0 ? dflt : v
}

// Lift the blinking cursor off the screen before an op that moves it or rewrites
// the cell under it, so no stale reverse-video block is left behind; the
// timer-driven blink repaints it at the new position.
private func fb_lift_cursor() {
    if g_cur_drawn {
        fb_restore_cell(g_cur_col, g_cur_row)
        g_cur_drawn = false
    }
}

// Clear cells [c0, c1) on row r to a blank in the current background colour
// (background-colour erase), updating both shadow buffers and the framebuffer.
// mc relies on this to flood its panels with the skin's blue background.
private func fb_clear_row_span(_ r: UInt, _ c0: UInt, _ c1in: UInt) {
    if r >= g_rows { return }
    var c1 = c1in
    if c1 > g_cols { c1 = g_cols }
    let attr = sgrAttr()
    let fg = attrFg(attr), bg = attrBg(attr)
    var c = c0
    while c < c1 {
        if r < UInt(MAX_ROWS) && c < UInt(MAX_COLS) {
            g_cells[Int(r) * MAX_COLS + Int(c)] = UInt8(ascii: " ")
            g_cell_attr[Int(r) * MAX_COLS + Int(c)] = attr
        }
        fb_render(UInt8(ascii: " "), c, r, fg, bg)
        c += 1
    }
}

// Erase in line (CSI K): 0 = cursor..eol, 1 = bol..cursor, 2 = whole line.
private func fb_erase_line(_ mode: Int32) {
    if mode == 1 { fb_clear_row_span(g_cy, 0, g_cx + 1) }
    else if mode == 2 { fb_clear_row_span(g_cy, 0, g_cols) }
    else { fb_clear_row_span(g_cy, g_cx, g_cols) }
}

// Erase in display (CSI J): 0 = cursor..end, 1 = start..cursor, 2 = all.
private func fb_erase_display(_ mode: Int32) {
    if mode == 2 {
        var r: UInt = 0
        while r < g_rows { fb_clear_row_span(r, 0, g_cols); r += 1 }
    } else if mode == 1 {
        var r: UInt = 0
        while r < g_cy { fb_clear_row_span(r, 0, g_cols); r += 1 }
        fb_clear_row_span(g_cy, 0, g_cx + 1)
    } else {
        fb_clear_row_span(g_cy, g_cx, g_cols)
        var r = g_cy + 1
        while r < g_rows { fb_clear_row_span(r, 0, g_cols); r += 1 }
    }
}

// Act on a complete CSI sequence whose final byte is `final`.
private func fb_csi_dispatch(_ final: UInt8) {
    switch final {
    case UInt8(ascii: "H"), UInt8(ascii: "f"):  // CUP — cursor position (1-based)
        let row = UInt(csi_param(0, 1))
        let col = UInt(csi_param(1, 1))
        fb_lift_cursor()
        g_cy = row - 1; if g_cy >= g_rows { g_cy = g_rows != 0 ? g_rows - 1 : 0 }
        g_cx = col - 1; if g_cx >= g_cols { g_cx = g_cols != 0 ? g_cols - 1 : 0 }
    case UInt8(ascii: "A"):                                                   // CUU
        let n = UInt(csi_param(0, 1)); fb_lift_cursor()
        g_cy = (n > g_cy) ? 0 : g_cy - n
    case UInt8(ascii: "B"):                                                   // CUD
        let n = UInt(csi_param(0, 1)); fb_lift_cursor()
        g_cy += n; if g_cy >= g_rows { g_cy = g_rows - 1 }
    case UInt8(ascii: "C"):                                                   // CUF
        let n = UInt(csi_param(0, 1)); fb_lift_cursor()
        g_cx += n; if g_cx >= g_cols { g_cx = g_cols - 1 }
    case UInt8(ascii: "D"):                                                   // CUB
        let n = UInt(csi_param(0, 1)); fb_lift_cursor()
        g_cx = (n > g_cx) ? 0 : g_cx - n
    case UInt8(ascii: "G"):                                                   // CHA
        let col = UInt(csi_param(0, 1)); fb_lift_cursor()
        g_cx = col - 1; if g_cx >= g_cols { g_cx = g_cols - 1 }
    case UInt8(ascii: "d"):                                                   // VPA
        let row = UInt(csi_param(0, 1)); fb_lift_cursor()
        g_cy = row - 1; if g_cy >= g_rows { g_cy = g_rows - 1 }
    case UInt8(ascii: "J"): fb_lift_cursor(); fb_erase_display(csi_param(0, 0)) // ED
    case UInt8(ascii: "K"): fb_lift_cursor(); fb_erase_line(csi_param(0, 0))    // EL
    case UInt8(ascii: "h"), UInt8(ascii: "l"):
        if g_csi_private {
            let mode = csi_param(0, 0)
            // Alternate screen buffer (xterm 1049/1047, DEC 47): vi repaints in
            // full, so clear + home on both enter and leave is enough.
            if mode == 1049 || mode == 1047 || mode == 47 {
                fb_lift_cursor(); fb_erase_display(2); g_cx = 0; g_cy = 0
            }
            // ?25 (cursor show/hide) and other private modes: ignored.
        }
    case UInt8(ascii: "m"): fb_apply_sgr()    // SGR — colour / bold / reverse
    default: break   // any other final byte: consumed, ignored
    }
}

// Apply an SGR (CSI m) sequence to the current colour state. Reads the raw
// parameter list directly (not csi_param, which folds 0 into a default) because
// 0 is a real SGR opcode (reset); an empty parameter list (ESC[m) means reset.
private func fb_apply_sgr() {
    let count = g_any ? (g_pidx + 1) : 0
    if count == 0 {
        g_sgr_fg = 7; g_sgr_bg = 0; g_sgr_bold = false; g_sgr_reverse = false
        return
    }
    var i = 0
    while i < count {
        switch g_params[i] {
        case 0:  g_sgr_fg = 7; g_sgr_bg = 0; g_sgr_bold = false; g_sgr_reverse = false
        case 1:  g_sgr_bold = true
        case 2, 22: g_sgr_bold = false             // faint / normal intensity
        case 7:  g_sgr_reverse = true
        case 27: g_sgr_reverse = false
        case 30...37:   g_sgr_fg = UInt8(g_params[i] - 30)
        case 39: g_sgr_fg = 7                       // default foreground
        case 40...47:   g_sgr_bg = UInt8(g_params[i] - 40)
        case 49: g_sgr_bg = 0                       // default background
        case 90...97:   g_sgr_fg = UInt8(g_params[i] - 90 + 8)   // bright fg
        case 100...107: g_sgr_bg = UInt8(g_params[i] - 100 + 8)  // bright bg
        default: break    // 38/48 (256-/true-colour) and unknowns: ignored
        }
        i += 1
    }
}

@_cdecl("fb_putc")
func fb_putc(_ c: UInt8) {
    if g_fb == 0 {
        return
    }

    switch g_state {
    case ST_ESC:
        if c == UInt8(ascii: "[") {           // CSI — collect parameters
            g_state = ST_CSI
            for i in 0..<MAX_PARAMS { g_params[i] = 0 }
            g_pidx = 0; g_any = false; g_csi_private = false
        } else if c == UInt8(ascii: "(") || c == UInt8(ascii: ")") || c == UInt8(ascii: "#") {
            g_state = ST_ESC_INTER            // charset/select: swallow next byte
        } else {
            g_state = ST_NORMAL               // ESC c, ESC =, ... : ignore
        }
        return
    case ST_ESC_INTER:
        g_state = ST_NORMAL                   // swallow the one designator byte
        return
    case ST_CSI:
        if c == UInt8(ascii: "?") { if !g_any { g_csi_private = true }; return }
        if c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") {
            g_params[g_pidx] = g_params[g_pidx] * 10 + Int32(c - UInt8(ascii: "0"))
            g_any = true
            return
        }
        if c == UInt8(ascii: ";") {
            g_any = true
            if g_pidx < MAX_PARAMS - 1 { g_pidx += 1 }
            return
        }
        if c >= 0x40 && c <= 0x7E {            // final byte
            fb_csi_dispatch(c)
            g_state = ST_NORMAL
            return
        }
        return                                 // intermediate/stray: stay, ignore
    default:
        break
    }

    if c == 0x1b { g_state = ST_ESC; return }

    if c == UInt8(ascii: "\n") {
        g_cx = 0
        g_cy += 1
    } else if c == UInt8(ascii: "\r") {
        g_cx = 0
    } else if c == 0x08 {          // '\b' — move left without erasing (line-edit cursor)
        if g_cx > 0 { g_cx -= 1 }
        return
    } else if c == UInt8(ascii: "\t") {
        g_cx = (g_cx + 4) & ~UInt(3)
    } else {
        if g_cx >= g_cols {
            g_cx = 0
            g_cy += 1
        }
        if g_cy >= g_rows {
            fb_scroll()
            g_cy = g_rows - 1
        }
        fb_draw_glyph(c, g_cx, g_cy)
        g_cx += 1
        return
    }
    if g_cy >= g_rows {
        fb_scroll()
        g_cy = g_rows - 1
    }
    // A line completed (newline/CR/tab). On a virtio-gpu scanout, a framebuffer
    // write is not shown until it is transferred + flushed; do that per line so
    // the boot log streams to a GPU-only console (no-op on ramfb/GOP/serial).
    gpuConsoleFlush()
}

// Drive the blinking block cursor. Called every timer tick; toggles the visible
// phase roughly once a second and reconciles the painted cell with where the
// text cursor (g_cx,g_cy) now is. No-op without a framebuffer.
@_cdecl("fb_cursor_blink")
func fb_cursor_blink() {
    if g_fb == 0 { return }
    g_blink_ctr += 1
    if g_blink_ctr >= 50 {          // ~0.5 s at the 100 Hz tick → 1 Hz blink
        g_blink_ctr = 0
        g_blink_on = !g_blink_on
    }
    // Lift the cursor if it should hide or the text cursor has moved.
    if g_cur_drawn && (!g_blink_on || g_cur_col != g_cx || g_cur_row != g_cy) {
        fb_restore_cell(g_cur_col, g_cur_row)
        g_cur_drawn = false
    }
    // Paint it at the current position while the phase is on.
    if g_blink_on && !g_cur_drawn && g_cx < g_cols && g_cy < g_rows {
        var c = g_cells[Int(g_cy) * MAX_COLS + Int(g_cx)]
        if c < 0x20 { c = UInt8(ascii: " ") }
        // Reverse-video block: swap the cell's own fg/bg, so the cursor inverts
        // whatever colour that cell carries rather than a fixed white block.
        let attr = g_cell_attr[Int(g_cy) * MAX_COLS + Int(g_cx)]
        fb_render(c, g_cx, g_cy, attrBg(attr), attrFg(attr))
        g_cur_col = g_cx
        g_cur_row = g_cy
        g_cur_drawn = true
    }
    // Periodically push the framebuffer to a virtio-gpu scanout so output with no
    // trailing newline (e.g. the "login:" prompt) and the cursor still appear.
    // ~6 Hz at the 100 Hz tick; no-op unless a virtio-gpu console is active.
    g_gpu_flush_ctr += 1
    if g_gpu_flush_ctr >= 16 {
        g_gpu_flush_ctr = 0
        gpuConsoleFlush()
    }
}

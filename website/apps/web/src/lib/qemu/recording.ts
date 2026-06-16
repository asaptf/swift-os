/* A faithful recorded boot + login session, played into an xterm.js terminal.
 *
 * Used as the honest fallback when the in-browser VM can't run (artifacts not
 * configured, or the browser isn't cross-origin isolated). Clearly labelled as
 * a recording in the UI. Colors use ANSI/truecolor to match the design tokens. */

const G = '\x1b[32m'; // ok / green
const D = '\x1b[90m'; // dim
const O = '\x1b[38;2;255;106;77m'; // swift-orange (prompt)
const C = '\x1b[38;2;232;234;237m'; // command / bright
const R = '\x1b[0m';
const prompt = `${O}root@swift-os${D}:~$${R} `;

interface Frame {
	text: string;
	delay: number;
}

export const BOOT_FRAMES: Frame[] = [
	{ text: `${D}QEMU 8.2.0 · virt · aarch64-cortex-a72${R}\r\n`, delay: 280 },
	{ text: `${D}UEFI: loading \\EFI\\BOOT\\BOOTAA64.EFI ...${R}\r\n`, delay: 240 },
	{ text: `${G}[ ok ]${R} swift-os kernel (Embedded Swift, signed)\r\n`, delay: 200 },
	{ text: `${G}[ ok ]${R} MMU enabled · EL1 · 256 MiB\r\n`, delay: 150 },
	{ text: `${G}[ ok ]${R} virtio-blk: mounted base.img (ro)\r\n`, delay: 150 },
	{ text: `${G}[ ok ]${R} virtio-net up · DHCPv4 10.0.2.15/24\r\n`, delay: 150 },
	{ text: `${G}[ ok ]${R} httpd listening on :8080\r\n`, delay: 150 },
	{ text: `${G}[ ok ]${R} llmd ready · POST /completion\r\n`, delay: 220 },
	{ text: `\r\n${D}Welcome to swift-os, root${R}\r\n`, delay: 260 },
	{ text: `swift-os login: ${C}root${R}\r\n`, delay: 520 },
	{ text: `Password: ${D}••••••••${R}\r\n\r\n`, delay: 420 },
	{ text: prompt, delay: 600 },
	{ text: `${C}id${R}\r\n`, delay: 360 },
	{ text: `session: principal=1 session=1 caps=63\r\n`, delay: 260 },
	{ text: prompt, delay: 500 },
	{ text: `${C}netinfo${R}\r\n`, delay: 360 },
	{ text: `ipv4 10.0.2.15/24  gw 10.0.2.2  dns 10.0.2.3\r\n`, delay: 260 },
	{ text: prompt, delay: 520 },
	{ text: `${C}tcpget 127.0.0.1 8080${R}\r\n`, delay: 520 },
	{ text: `HTTP/1.1 200 OK · served by swift-os httpd\r\n`, delay: 300 },
	{ text: prompt, delay: 400 }
];

export interface Term {
	write(data: string): void;
}

/** Play the recorded frames into a terminal. Resolves when done or aborted. */
export async function playRecording(term: Term, signal?: { aborted: boolean }): Promise<void> {
	for (const f of BOOT_FRAMES) {
		if (signal?.aborted) return;
		term.write(f.text);
		await new Promise((r) => setTimeout(r, f.delay));
	}
}

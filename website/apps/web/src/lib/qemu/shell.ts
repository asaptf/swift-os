/* A small SIMULATED interactive shell for the recorded-boot fallback, so the
 * keyboard works on /try even before the live WASM VM is wired up. It is NOT a
 * real OS — it answers a fixed command set with swift-os-accurate output, and
 * is clearly labelled "demo" in the UI. The real in-browser VM (boot.ts) takes
 * genuine keyboard input through the guest PTY. */

import type { Terminal } from '@xterm/xterm';

const O = '\x1b[38;2;255;106;77m'; // prompt orange
const D = '\x1b[90m'; // dim
const G = '\x1b[32m'; // ok green
const R = '\x1b[0m';
const PROMPT = `${O}root@swift-os${D}:~$${R} `;
const NL = '\r\n';

const MOTD = [
	'  swift-os — a real OS in Embedded Swift (aarch64)',
	'  base.img is read-only · /tmp is tmpfs and resets on reboot',
	'  type `help` for the commands this demo shell understands'
].join(NL);

const HELP = [
	'Available (demo) commands:',
	`  ${G}id${R}            principal, session & capability mask`,
	`  ${G}whoami${R}        current principal`,
	`  ${G}uname -a${R}      kernel / arch`,
	`  ${G}ls [-l] /${R}     list the root filesystem`,
	`  ${G}cat${R} <file>    /etc/motd, /etc/os-release`,
	`  ${G}ps${R}            running processes`,
	`  ${G}netinfo${R}       network status (ip / gw / dns)`,
	`  ${G}tcpget${R} h p    fetch from httpd · ${G}llmd${R} inference`,
	`  ${G}echo${R} <text>   pwd · uptime · free · clear · help`
].join(NL);

const LS_PLAIN = 'bin   etc   lib   sbin   tmp   usr   www';
const LS_LONG = [
	'dr-xr-xr-x  1 root root   0 bin',
	'dr-xr-xr-x  1 root root   0 etc',
	'dr-xr-xr-x  1 root root   0 lib',
	'dr-xr-xr-x  1 root root   0 sbin',
	'drwxrwxrwt  1 root root   0 tmp   ' + D + '(tmpfs)' + R,
	'dr-xr-xr-x  1 root root   0 usr',
	'dr-xr-xr-x  1 root root   0 www   ' + D + '(httpd docroot)' + R
].join(NL);

const PS = [
	'  PID  PRINCIPAL  EL  CMD',
	'    1  root       0   /bin/swos-init',
	'    7  root       0   /bin/httpd   ' + D + 'caps=[net:bind] :8080' + R,
	'    9  root       0   /bin/llmd    ' + D + 'TinyStories :8080' + R,
	'   12  root       0   /bin/console-login',
	'   19  root       0   busybox ash'
].join(NL);

const FILES: Record<string, string> = {
	'/etc/motd': MOTD,
	'/etc/os-release':
		'NAME="swift-os"\r\nID=swift-os\r\nARCH=aarch64\r\nKERNEL="Embedded Swift"\r\nVERSION="rolling (built from source)"'
};

/** Returns command output (CRLF-joined), '' for a bare prompt, or the sentinel
 *  '\x0c' to clear the screen. */
function run(input: string): string {
	const line = input.trim();
	if (!line) return '';
	const [cmd, ...args] = line.split(/\s+/);
	const arg = args.join(' ');

	switch (cmd) {
		case 'help':
		case '?':
			return HELP;
		case 'id':
			return 'session: principal=1 session=1 caps=63';
		case 'whoami':
			return 'root';
		case 'uname':
			return args.includes('-a') ? 'swift-os aarch64 SwiftKernel (Embedded Swift)' : 'swift-os';
		case 'pwd':
			return '/root';
		case 'ls':
			return args.includes('-l') ? LS_LONG : LS_PLAIN;
		case 'cat': {
			if (!arg) return 'cat: missing operand';
			const f = arg.startsWith('/') ? arg : `/etc/${arg}`;
			return FILES[f] ?? FILES[arg] ?? `cat: ${arg}: no such file`;
		}
		case 'ps':
			return PS;
		case 'netinfo':
			return 'ipv4 10.0.2.15/24  gw 10.0.2.2  dns 10.0.2.3  (DHCPv4, virtio-net)';
		case 'tcpget':
			return args.length >= 2
				? 'HTTP/1.1 200 OK\r\nServer: swift-os httpd\r\nContent-Type: text/html\r\n\r\n<h1>served by swift-os</h1>'
				: 'usage: tcpget host port   (e.g. tcpget 127.0.0.1 8080)';
		case 'llmd':
			return `${D}llmd listening on :8080 — GET /health · POST /completion${R}`;
		case 'httpd':
			return `${D}httpd serving /www on :8080${R}`;
		case 'curl':
			return `${D}curl is a seed package — install it with: pkg install curl. The built-in TCP client is \`tcpget host port\`.${R}`;
		case 'echo':
			return arg;
		case 'uptime':
			return 'up 00:04:11 · 0 panics · load 0.00';
		case 'free':
			return 'mem: 256 MiB total · 31 MiB used · base.img ro · /tmp tmpfs';
		case 'clear':
			return '\x0c';
		case 'reboot':
		case 'exit':
			return `${D}(demo) reboot would wipe /tmp and start from the signed base.img${R}`;
		default:
			return `swsh: command not found: ${cmd}  ${D}(try \`help\`)${R}`;
	}
}

/** Attach an interactive demo shell to the terminal. Returns a disposer. */
export function attachDemoShell(term: Terminal): () => void {
	let line = '';
	const history: string[] = [];
	let hist = 0;

	const redraw = (next: string) => {
		// clear current line, reprint prompt + buffer
		term.write('\r\x1b[K' + PROMPT + next);
		line = next;
	};

	// The recorded boot leaves a fresh prompt on screen; demonstrate `echo` and
	// invite input, then drop to the live (simulated) prompt.
	const greeting = 'Now you can type your commands here';
	term.write(`echo "${greeting}"${NL}${greeting}${NL}${PROMPT}`);
	term.focus();

	const sub = term.onData((data: string) => {
		// history navigation (whole escape sequences)
		if (data === '\x1b[A') {
			if (history.length && hist > 0) redraw(history[--hist]);
			return;
		}
		if (data === '\x1b[B') {
			if (hist < history.length - 1) redraw(history[++hist]);
			else {
				hist = history.length;
				redraw('');
			}
			return;
		}
		if (data === '\x1b[C' || data === '\x1b[D') return; // ignore left/right
		// Swallow any other escape sequence (Insert/Home/PageUp/F-keys, bracketed
		// paste, …) so its bytes never leak into the line buffer.
		if (data.charCodeAt(0) === 27) return;

		for (const ch of data) {
			const code = ch.charCodeAt(0);
			if (ch === '\r' || ch === '\n') {
				term.write(NL);
				const out = run(line);
				if (out === '\x0c') {
					term.clear();
				} else if (out) {
					term.write(out + NL);
				}
				if (line.trim()) history.push(line.trim());
				hist = history.length;
				line = '';
				term.write(PROMPT);
			} else if (code === 127 || ch === '\b') {
				if (line.length) {
					line = line.slice(0, -1);
					term.write('\b \b');
				}
			} else if (code === 3) {
				term.write('^C' + NL + PROMPT);
				line = '';
			} else if (code === 12) {
				term.clear();
				term.write(PROMPT + line);
			} else if (code >= 32) {
				line += ch;
				term.write(ch);
			}
		}
	});

	return () => sub.dispose();
}

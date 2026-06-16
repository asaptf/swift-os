/* Terminal / shell-output highlighter.
 *
 * CMS- or repo-authored plain terminal text gets the design's token colors
 * (t-prompt / t-ok / t-comment / …) applied by pattern, so editors can write
 * plain text and still match the prototype's colored output exactly. */

function esc(s: string): string {
	return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function highlightLine(raw: string): string {
	const line = esc(raw);

	// status prefixes
	let m = line.match(/^(\s*)(\[ ok \])(.*)$/);
	if (m) return `${m[1]}<span class="t-ok">${m[2]}</span>${m[3]}`;
	m = line.match(/^(\s*)(\[info\]|\[warn\]|\[ \.\. \])(.*)$/);
	if (m) {
		const cls = m[2] === '[warn]' ? 't-warn' : 't-dim';
		return `${m[1]}<span class="${cls}">${m[2]}</span>${m[3]}`;
	}
	m = line.match(/^(\s*)(PASS)(\s+.*)$/);
	if (m) return `${m[1]}<span class="t-ok">${m[2]}</span><span class="t-dim">${m[3]}</span>`;
	m = line.match(/^(\s*)(FAIL)(\s+.*)$/);
	if (m) return `${m[1]}<span class="t-warn">${m[2]}</span>${m[3]}`;

	// shell prompts: "$ cmd" or "root@swift-os:~$ cmd"
	m = line.match(/^(\s*)(root@swift-os)(:[~\w/.-]*\$)(\s)(.*)$/);
	if (m)
		return `${m[1]}<span class="t-prompt">${m[2]}</span><span class="t-dim">${m[3]}</span>${m[4]}<span class="t-cmd">${m[5]}</span>`;
	m = line.match(/^(\s*)(\$)(\s)(.*)$/);
	if (m) return `${m[1]}<span class="t-prompt">${m[2]}</span>${m[3]}<span class="t-cmd">${m[4]}</span>`;

	// comments
	m = line.match(/^(\s*)(#.*)$/);
	if (m) return `${m[1]}<span class="t-comment">${m[2]}</span>`;

	// box-drawing summary line "─── … ───"
	if (/^\s*─.*─\s*$/.test(raw)) return `<span class="t-dim">${line}</span>`;

	return line;
}

/** Render plain terminal text to token-colored HTML for a <pre class="code-block">. */
export function terminalHTML(text: string): string {
	return text.replace(/\r\n/g, '\n').replace(/\n+$/, '').split('\n').map(highlightLine).join('\n');
}

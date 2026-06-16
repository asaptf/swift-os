#!/usr/bin/env node
/* Run the Strapi CMS and the SvelteKit web app together, with prefixed,
 * color-coded output. No extra dependencies. */
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

const procs = [
	{ name: 'cms', color: '\x1b[36m', dir: 'apps/cms', args: ['run', 'develop'] },
	{ name: 'web', color: '\x1b[35m', dir: 'apps/web', args: ['run', 'dev'] }
];

const children = [];

function run({ name, color, dir, args }) {
	const child = spawn('npm', args, {
		cwd: path.join(root, dir),
		env: process.env,
		stdio: ['ignore', 'pipe', 'pipe']
	});
	const tag = `${color}[${name}]\x1b[0m `;
	const pipe = (stream, out) => {
		let buf = '';
		stream.on('data', (d) => {
			buf += d.toString();
			const lines = buf.split('\n');
			buf = lines.pop() ?? '';
			for (const l of lines) out.write(tag + l + '\n');
		});
	};
	pipe(child.stdout, process.stdout);
	pipe(child.stderr, process.stderr);
	child.on('exit', (code) => {
		process.stdout.write(tag + `exited with code ${code}\n`);
		shutdown();
	});
	children.push(child);
}

function shutdown() {
	for (const c of children) {
		if (!c.killed) c.kill('SIGTERM');
	}
	process.exit(0);
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

console.log('Starting swift-os website — web → http://localhost:5180 · CMS → http://localhost:1337/admin\n');
procs.forEach(run);

// `npm run dev`: start the local Supabase stand-in (devserver, port 54321) and
// serve the Flutter web build (port 8080). Builds the web app first if needed.

import { spawn, spawnSync } from 'node:child_process';
import { existsSync, readFileSync, statSync } from 'node:fs';
import http from 'node:http';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const webDir = join(root, 'app', 'build', 'web');
const APP_PORT = 8080;
const isWin = process.platform === 'win32';

function run(cmd, args, cwd) {
  const r = spawnSync(cmd, args, { cwd, stdio: 'inherit', shell: isWin });
  if (r.status !== 0) process.exit(r.status ?? 1);
}

// 1. Dependencies for the local backend.
if (!existsSync(join(root, 'devserver', 'node_modules'))) {
  console.log('Installing local backend dependencies…');
  run('npm', ['install'], join(root, 'devserver'));
}

// 2. Web build of the Flutter app (only when missing; `npm run build:web` to rebuild).
if (!existsSync(join(webDir, 'index.html'))) {
  console.log('Building the Nouri web app (first run, takes a few minutes)…');
  run('npm', ['run', 'build:web'], root);
}

// 3. Local backend.
const backend = spawn(process.execPath, ['server.mjs'], { cwd: join(root, 'devserver'), stdio: 'inherit' });
backend.on('exit', (code) => {
  console.log(`Local backend stopped (code ${code}).`);
  process.exit(code ?? 0);
});

// 4. Static server for the web build.
const types = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json',
  '.css': 'text/css', '.png': 'image/png', '.jpg': 'image/jpeg', '.svg': 'image/svg+xml', '.ico': 'image/x-icon',
  '.wasm': 'application/wasm', '.otf': 'font/otf', '.ttf': 'font/ttf', '.woff2': 'font/woff2',
};
http.createServer((req, res) => {
  const path = normalize(decodeURIComponent(new URL(req.url, 'http://x').pathname)).replace(/^([/\\])+/, '');
  let file = join(webDir, path);
  if (!file.startsWith(webDir) || !existsSync(file) || statSync(file).isDirectory()) file = join(webDir, 'index.html');
  res.writeHead(200, { 'Content-Type': types[extname(file)] ?? 'application/octet-stream', 'Cache-Control': 'no-store' });
  res.end(readFileSync(file));
}).on('error', (e) => {
  console.error(e.code === 'EADDRINUSE' ? `Port ${APP_PORT} is already in use. Close the other server and try again.` : e);
  backend.kill();
  process.exit(1);
}).listen(APP_PORT, () => {
  console.log(`\n  Nouri is running:  http://localhost:${APP_PORT}`);
  console.log('  Demo accounts (password demo1234): selin@ / elif@ / deniz@ / admin@nouri.demo');
  console.log('  Press Ctrl+C to stop.\n');
});

// On Ctrl+C the backend receives the signal too and closes its database
// itself; wait for it instead of killing it mid-write.
process.on('SIGINT', () => {
  setTimeout(() => process.exit(0), 5000).unref();
});

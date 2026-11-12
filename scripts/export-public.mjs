// Copy the shareable part of the project into a separate folder for a public
// GitHub repository, after checking it for secrets.
//
//   npm run export:public                 -> Desktop/Nouri
//   node scripts/export-public.mjs <dir>  -> another folder
//
// Which files: everything git would commit here (all .gitignore files apply),
// so local data, keys, builds and caches never leave this machine. Run it again
// after changes: the folder is updated in place and its .git is kept, so
// GitHub Desktop shows only what changed.
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, copyFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { dirname, join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const target = process.argv[2] ?? join(homedir(), 'Desktop', 'Nouri');

// --- git (PATH, or the copy bundled with GitHub Desktop on Windows) ----------------
function findGit() {
  try { execFileSync('git', ['--version'], { stdio: 'ignore' }); return 'git'; } catch { /* not on PATH */ }
  const base = join(process.env.LOCALAPPDATA ?? '', 'GitHubDesktop');
  if (existsSync(base)) {
    for (const app of readdirSync(base).filter((d) => d.startsWith('app-')).sort().reverse()) {
      const exe = join(base, app, 'resources', 'app', 'git', 'cmd', 'git.exe');
      if (existsSync(exe)) return exe;
    }
  }
  throw new Error('git not found. Install Git or GitHub Desktop.');
}

const git = findGit();
// A throwaway repository outside the project, used only to ask git which files
// it would commit (the project folder itself is not turned into a repository).
const scratch = mkdtempSync(join(tmpdir(), 'nouri-export-'));
const gitDir = join(scratch, 'git');
execFileSync(git, ['init', '--quiet', '--bare', gitDir]);
const files = execFileSync(git, ['-c', 'core.quotepath=off', '-c', 'core.bare=false', `--git-dir=${gitDir}`, `--work-tree=${root}`,
  'ls-files', '--others', '--exclude-standard', '-z'], { encoding: 'utf8', maxBuffer: 1 << 26 })
  .split('\0').filter(Boolean).sort();
rmSync(scratch, { recursive: true, force: true });

// --- secret scan -------------------------------------------------------------------
const textExt = /\.(dart|mjs|js|ts|json|sql|md|yaml|yml|xml|gradle|kts|properties|plist|html|txt|sh|swift|kt|java|example|gitignore|xcconfig|pbxproj|cfg|toml)$/i;
const okEmail = /@(nouri\.demo|example\.com|x\.test|test-project\.iam\.gserviceaccount\.com|users\.noreply\.github\.com)$/i;
const checks = [
  ['private IP address', /\b(?:192\.168|10\.(?!0\.2\.2\b)\d{1,3}|172\.(?:1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}\b/],
  ['Anthropic key', /sk-ant-[A-Za-z0-9_-]{20,}/],
  ['OpenAI-style key', /\bsk-[A-Za-z0-9]{32,}/],
  ['Google API key', /AIza[0-9A-Za-z_-]{35}/],
  ['JWT / Supabase key', /eyJ[A-Za-z0-9_-]{20,}\.eyJ[A-Za-z0-9_-]{20,}/],
  ['Supabase secret key', /sb_secret_[A-Za-z0-9_-]{10,}/],
  ['private key', /-----BEGIN [A-Z ]*PRIVATE KEY-----/],
  ['GitHub token', /\bgh[pousr]_[A-Za-z0-9]{30,}/],
  ['personal path', /[A-Za-z]:\\+Users\\+[^\\\s"'`]+/],
];
const problems = [];
for (const f of files) {
  const base = f.split('/').pop();
  if (/^\.env($|\.)/.test(base) && base !== '.env.example') problems.push(`${f}: environment file`);
  if (/\.(jks|keystore|p12|p8|pem)$|^key\.properties$|^local\.properties$|google-services\.json|GoogleService-Info\.plist/i.test(base)) problems.push(`${f}: key/config file`);
  const full = join(root, f);
  if (statSync(full).size > 95 * 1024 * 1024) problems.push(`${f}: larger than GitHub's 100 MB limit`);
  if (!textExt.test(f) || statSync(full).size > 5 * 1024 * 1024) continue;
  const text = readFileSync(full, 'utf8');
  text.split('\n').forEach((line, i) => {
    for (const [what, re] of checks) if (re.test(line)) problems.push(`${f}:${i + 1}: ${what}`);
    for (const m of line.matchAll(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g)) {
      if (/\.(png|jpe?g|webp|gif|svg)$/i.test(m[0])) continue; // image names like Icon@2x.png
      if (!okEmail.test(m[0]) && !/^(you|name|someone|contact)@/i.test(m[0])) problems.push(`${f}:${i + 1}: e-mail address ${m[0]}`);
    }
  });
}
if (problems.length) {
  console.error('Not exported. Fix these first:\n  ' + problems.join('\n  '));
  process.exit(1);
}

// --- sync into the target folder (its .git is left alone) -------------------------
mkdirSync(target, { recursive: true });
const wanted = new Set(files.map((f) => f.split('/').join(sep)));
let removed = 0;
(function prune(dir) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    const rel = relative(target, p);
    // Kept: the repository itself and files GitHub adds when creating one.
    if (['.git', '.gitattributes', 'LICENSE', 'LICENSE.md', 'LICENSE.txt'].includes(rel)) continue;
    if (statSync(p).isDirectory()) {
      prune(p);
      if (!readdirSync(p).length) rmSync(p, { recursive: true });
    } else if (!wanted.has(rel)) { rmSync(p); removed++; }
  }
})(target);

let copied = 0;
for (const f of files) {
  const src = join(root, f);
  const dst = join(target, f);
  if (existsSync(dst) && statSync(dst).size === statSync(src).size && readFileSync(dst).equals(readFileSync(src))) continue;
  mkdirSync(dirname(dst), { recursive: true });
  copyFileSync(src, dst);
  copied++;
}
console.log(`Public copy: ${target}\n  ${files.length} files, ${copied} new or changed, ${removed} removed. No secrets found.`);

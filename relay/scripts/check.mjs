// Syntax-checks every .js / .mjs file under src, public, scripts, and test.
// Skips a directory only when it does not exist.

import { readdir, stat } from 'node:fs/promises';
import { join, extname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const run = promisify(execFile);
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const DIRS = ['src', 'public', 'scripts', 'test'];

async function walk(dir) {
  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch (err) {
    if (err.code === 'ENOENT') return [];
    throw err;
  }
  const out = [];
  for (const e of entries) {
    const p = join(dir, e.name);
    if (e.isDirectory()) out.push(...(await walk(p)));
    else if (['.js', '.mjs'].includes(extname(e.name))) out.push(p);
  }
  return out;
}

const files = (await Promise.all(DIRS.map((d) => walk(join(ROOT, d))))).flat();

if (files.length === 0) {
  console.error('check: no JavaScript files found');
  process.exit(1);
}

let failed = 0;
for (const file of files) {
  try {
    await run(process.execPath, ['--check', file]);
  } catch (err) {
    failed += 1;
    console.error(`FAIL ${file}\n${err.stderr ?? err.message}`);
  }
}

console.log(`check: ${files.length - failed}/${files.length} files parsed`);
process.exit(failed === 0 ? 0 : 1);

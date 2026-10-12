#!/usr/bin/env node
// Copy the dashboard to Home Assistant's www folder and cache-bust it.
//
//   node deploy.mjs --project <dir> [--to <path>] [--dry-run] [--allow-admin]
//
// --to is the www/<name> folder as THIS machine sees it, e.g.
//   Windows: \\homeassistant.local\config\www\wall      (Samba share add-on)
//   macOS:   /Volumes/config/www/wall
//   Linux:   /mnt/ha-config/www/wall
// Defaults to deployTo in dashboard.project.json.
//
// Why the stamping: HA serves /local/ with a 31-day cache and a kiosk browser
// has no hard refresh. Every literal relative import (`from './x.js'`) and the
// stylesheet link get ?v=<timestamp> in the DEPLOYED copies only; the source
// stays clean so tests keep working. index.html busts itself (see its script).
import { cpSync, existsSync, readdirSync, readFileSync, writeFileSync, statSync } from 'node:fs';
import { basename, dirname, join, resolve, relative, sep } from 'node:path';
import { parseArgs } from 'node:util';
import { readProject, normalizeShare, wsSession, fail } from './lib/ha.mjs';

const { values: args } = parseArgs({
  options: {
    project: { type: 'string', default: '.' },
    to: { type: 'string' },
    'dry-run': { type: 'boolean', default: false },
    'allow-admin': { type: 'boolean', default: false },
  },
});

const src = join(resolve(args.project), 'www');
const raw = normalizeShare(args.to ?? readProject(args.project).deployTo ?? '');
if (!raw) fail('No destination. Pass --to <path to config/www/<name>> or set deployTo in dashboard.project.json.');
// Judge the RESOLVED path: a textual check would let www/.. through to the config root.
const dest = resolve(raw);
if (basename(dirname(dest)) !== 'www' || ['.', '..', ''].includes(basename(dest))) {
  fail(`Refusing to deploy to "${raw}": expected a folder directly under HA's config/www (…/www/<name>). Nothing outside it should ever be overwritten.`);
}
if (!existsSync(join(src, 'config.local.js'))) fail('www/config.local.js is missing — the dashboard cannot log in without it.');
const tabletToken = readFileSync(join(src, 'config.local.js'), 'utf8').match(/HA_TOKEN\s*=\s*['"]([^'"]+)['"]/)?.[1] ?? '';
if (!tabletToken || tabletToken.startsWith('PASTE_')) fail('www/config.local.js still has the placeholder token.');
if (!existsSync(join(src, 'dashboard.config.js'))) fail('www/dashboard.config.js is missing — run the setup wizard first.');

// config.local.js is served WITHOUT authentication. An admin token there means
// anyone who can reach /local/ (the LAN, or the internet via a proxy or
// Nabu Casa) can take over Home Assistant. Refuse unless explicitly allowed.
const haUrl = readProject(args.project).haUrl;
if (haUrl && !args['dry-run']) {
  try {
    const ha = await wsSession(haUrl, tabletToken);
    const me = await ha.request({ type: 'auth/current_user' });
    ha.close();
    if (me?.is_admin && !args['allow-admin']) {
      fail(`The token in www/config.local.js belongs to "${me.name}", an ADMIN user, and that file is served without login. `
        + 'Use a non-admin user for the tablet (see deploy.md), or pass --allow-admin to accept the risk for now.');
    }
    if (me?.is_admin) console.log(`warning: deploying an admin token ("${me.name}") because --allow-admin was given.`);
  } catch (e) {
    console.log(`warning: could not verify the tablet token against ${haUrl} (${e.message}); deploying anyway.`);
  }
}

// Not deployed: tests, templates, Node-only files.
const SKIP = (rel) => rel.startsWith(`tests${sep}`) || rel === 'tests' || rel.endsWith('.example.js')
  || rel === 'package.json' || rel.startsWith('.') || rel.endsWith('.orig');

const files = [];
(function list(dir) {
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    const rel = relative(src, full);
    if (SKIP(rel)) continue;
    if (statSync(full).isDirectory()) list(full); else files.push(rel);
  }
})(src);

if (args['dry-run']) {
  console.log(`Would copy ${files.length} files to ${dest}:`);
  files.forEach((f) => console.log(`  ${f}`));
  process.exit(0);
}

const parent = resolve(dest, '..');
if (!existsSync(parent)) {
  fail(`Cannot see ${parent}. Is the share mounted / the Samba add-on running? (Windows: open it once in Explorer to log in.)`);
}

for (const f of files) cpSync(join(src, f), join(dest, f), { recursive: true, force: true });

const v = new Date().toISOString().replace(/\D/g, '').slice(0, 14);
// `from './x.js'`, bare `import './x.js'` and literal `import('./x.js')`.
const stampImports = (s) => s.replace(/((?:\bfrom\s+|\bimport\s*\(?\s*)['"](?:\.\/|\.\.\/)[^'"?]+?\.js)(['"])/g, `$1?v=${v}$2`);
for (const f of files) {
  const p = join(dest, f);
  if (f.endsWith('.js')) writeFileSync(p, stampImports(readFileSync(p, 'utf8')));
  if (f.endsWith('.html')) {
    let h = readFileSync(p, 'utf8');
    h = h.replace(/(href=["']\.\/style\.css)(["'])/g, `$1?v=${v}$2`);
    writeFileSync(p, stampImports(h));
  }
}

const name = dest.split(/[\\/]/).filter(Boolean).pop();
console.log(`Deployed ${files.length} files to ${dest}  [v=${v}]`);
console.log(`Open: <your HA url>/local/${name}/index.html   (theme preview: /local/${name}/themes.html)`);

#!/usr/bin/env node
// Create a dashboard project from the starter, or upgrade one to a newer
// starter without trampling local changes.
//
//   node scaffold.mjs --to <dir> --name wall [--ha-url http://homeassistant.local:8123] [--deploy-to <path>]
//   node scaffold.mjs --to <dir> --upgrade [--force]
//
// Project layout:
//   <dir>/dashboard.project.json   name, HA url, deploy target
//   <dir>/DASHBOARD.md             the home's notes: choices, quirks, decisions
//   <dir>/CLAUDE.md                tells future agent sessions to load this skill
//   <dir>/www/                     the web app; deployed to HA config/www/<name>
//   <dir>/www/.starter-manifest.json  hashes of starter files as copied
//
// Upgrade compares each local starter file with the hash it had when copied:
// unchanged files are replaced, locally edited ones are left alone and listed
// (pass --force to replace them anyway). dashboard.config.js and
// config.local.js are never touched by an upgrade.
import { createHash } from 'node:crypto';
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { fail, normalizeShare } from './lib/ha.mjs';

const { values: args } = parseArgs({
  options: {
    to: { type: 'string' },
    name: { type: 'string', default: 'wall' },
    'ha-url': { type: 'string' },
    'deploy-to': { type: 'string' },
    upgrade: { type: 'boolean', default: false },
    force: { type: 'boolean', default: false },
  },
});
if (!args.to) fail('Pass --to <project directory>.');
if (!/^[a-z0-9][a-z0-9-]*$/.test(args.name)) fail('--name must be lowercase letters, digits and dashes (it becomes the URL /local/<name>/).');

const skill = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const starter = join(skill, 'assets', 'starter');
const templates = join(skill, 'assets', 'templates');
const project = resolve(args.to);
const www = join(project, 'www');
const manifestPath = join(www, '.starter-manifest.json');

// Files the user owns from day one: created once from their .example, never upgraded.
const OWNED = new Set(['dashboard.config.js', 'config.local.js']);
// Text is hashed with line endings normalised: a checkout with
// core.autocrlf=true would otherwise make every file look locally edited, and
// the upgrade would keep (skip) all of them.
const TEXT = /\.(js|mjs|css|html|json|md)$/;
const hash = (p) => {
  const buf = readFileSync(p);
  const data = TEXT.test(p) ? buf.toString('utf8').replace(/\r\n/g, '\n') : buf;
  return createHash('sha256').update(data).digest('hex');
};

function starterFiles(dir = starter, out = []) {
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) starterFiles(full, out);
    else out.push(relative(starter, full).replaceAll('\\', '/'));
  }
  return out;
}

if (!args.upgrade) {
  if (existsSync(www)) fail(`${www} already exists. Use --upgrade to update the starter files in it.`);
  mkdirSync(www, { recursive: true });
  const manifest = {};
  for (const f of starterFiles()) {
    cpSync(join(starter, f), join(www, f), { recursive: true });
    manifest[f] = hash(join(starter, f));
  }
  cpSync(join(www, 'dashboard.config.example.js'), join(www, 'dashboard.config.js'));
  cpSync(join(www, 'config.local.example.js'), join(www, 'config.local.js'));
  writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));

  const fill = (s) => s.replaceAll('{{NAME}}', args.name).replaceAll('{{DATE}}', new Date().toISOString().slice(0, 10));
  for (const [tpl, target] of [['DASHBOARD.md', 'DASHBOARD.md'], ['CLAUDE.md', 'CLAUDE.md'], ['gitignore', '.gitignore']]) {
    const dest = join(project, target);
    if (!existsSync(dest)) writeFileSync(dest, fill(readFileSync(join(templates, tpl), 'utf8')));
  }
  const projFile = join(project, 'dashboard.project.json');
  if (!existsSync(projFile)) {
    writeFileSync(projFile, JSON.stringify({
      name: args.name,
      haUrl: args['ha-url'] ?? '',
      // Forward slashes: //host/config/www/x works on Windows too, and survives
      // shells and JSON escaping, where a \\host UNC path loses backslashes.
      deployTo: normalizeShare(args['deploy-to'] ?? ''),
    }, null, 2) + '\n');
  }
  console.log(`Created ${project}`);
  console.log('Next: paste the token into www/config.local.js, then run discover.mjs.');
  process.exit(0);
}

// ---- upgrade ----
if (!existsSync(www)) fail(`${www} does not exist — scaffold it first (without --upgrade).`);
const old = existsSync(manifestPath) ? JSON.parse(readFileSync(manifestPath, 'utf8')) : {};
const next = { ...old };
const replaced = [], added = [], kept = [], same = [];
for (const f of starterFiles()) {
  if (OWNED.has(f)) continue;
  const from = join(starter, f), to = join(www, f);
  const newHash = hash(from);
  if (!existsSync(to)) {
    mkdirSync(dirname(to), { recursive: true });
    cpSync(from, to); next[f] = newHash; added.push(f); continue;
  }
  const localHash = hash(to);
  if (localHash === newHash) { next[f] = newHash; same.push(f); continue; }
  const untouched = old[f] && localHash === old[f];
  if (untouched) { cpSync(from, to); next[f] = newHash; replaced.push(f); }
  else if (args.force) {
    cpSync(to, `${to}.orig`); // local edits survive --force, next to the new file
    cpSync(from, to); next[f] = newHash; replaced.push(`${f}  (local version saved as ${f}.orig)`);
  } else kept.push(f);
}
writeFileSync(manifestPath, JSON.stringify(next, null, 2));
console.log(`Upgrade: ${replaced.length} replaced, ${added.length} added, ${same.length} already current, ${kept.length} kept (edited locally).`);
for (const f of replaced) console.log(`  replaced  ${f}`);
for (const f of added) console.log(`  added     ${f}`);
for (const f of kept) console.log(`  KEPT      ${f}   <- local edits; diff against ${join(starter, f)} and merge by hand, or --force`);

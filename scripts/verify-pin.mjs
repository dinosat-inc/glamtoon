/**
 * Check that a pinned CID really holds every file.
 *
 * A directory CID resolves even when files are missing from it, so a finished
 * upload is not evidence of a complete one. This walks the 20,000 paths the
 * contract can build under a root for one extension, hashes what the gateway
 * returns and compares it against the copy on disk.
 *
 *   node scripts/verify-pin.mjs --cid bafy... --dir glamtoon --ext .png
 *   node scripts/verify-pin.mjs --cid bafy... --dir glamtoon --ext .webp
 *
 * Options:
 *   --gateway URL   default https://ipfs.filebase.io/ipfs/
 *   --jobs N        parallel requests, default 8
 *   --count N       characters to check, default 10000
 *   --sample N      check N random characters instead of the first N
 *   --out FILE      write the failing paths here, one per line
 *
 * A public gateway answers from whichever node holds the blocks, so a clean run
 * through one shows the CID is complete somewhere, not that one service pins
 * it. To check a service, use its own gateway. ipfs.io and dweb.link answer
 * every file request with 429, so they cannot be used here.
 *
 * A 404 or 410 is reported at once and never retried. A 429 or 503 pauses
 * every worker for as long as the gateway's Retry-After asks, never less than
 * the usual backoff and never more than two minutes. A gateway that asks for
 * longer ends the run, and whatever failed before that is still reported.
 *
 * Exits non-zero if anything is missing or does not match, or if the run
 * stopped before every file was checked.
 */

import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

const args = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  return i === -1 ? fallback : args[i + 1];
};

const CID = opt('cid');
const DIR = opt('dir');
const EXT = opt('ext');
const GATEWAY = opt('gateway', 'https://ipfs.filebase.io/ipfs/');
const JOBS = Number(opt('jobs', 8));
const COUNT = Number(opt('count', 10000));
const SAMPLE = Number(opt('sample', 0));
const OUT = opt('out');
const EDITIONS = ['blue', 'green'];
const ATTEMPTS = 5;
const MAX_WAIT = 120;

if (!CID || !DIR || !EXT) {
  console.error('need --cid, --dir and --ext. See the header of this file.');
  process.exit(2);
}

const sha256 = (buf) => createHash('sha256').update(buf).digest('hex');

/** Which characters to check. A spread says more than the first N. */
const ids = (() => {
  if (!SAMPLE) return Array.from({ length: COUNT }, (_, i) => i);
  const picked = new Set();
  while (picked.size < Math.min(SAMPLE, COUNT)) {
    picked.add(Math.floor(Math.random() * COUNT));
  }
  return [...picked].sort((a, b) => a - b);
})();

const jobs = [];
for (const edition of EDITIONS) {
  for (const id of ids) jobs.push({ edition, id });
}

const failures = [];
let checked = 0;
let bytes = 0;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** Seconds a refusal asks us to wait, or null when it does not say. */
function retryAfter(res) {
  const header = res.headers.get('retry-after');
  if (!header) return null;
  const seconds = Number(header);
  if (Number.isFinite(seconds)) return Math.max(0, seconds);
  const at = Date.parse(header);
  return Number.isNaN(at) ? null : Math.max(0, (at - Date.now()) / 1000);
}

/** Doubling waits with some jitter, so the workers do not retry in step. */
const backoff = (attempt) => Math.min(MAX_WAIT, 2 ** attempt) + Math.random();

// Shared by every worker, so one 429 slows them all rather than just the one
// that got it. Each wakes up to a second late, so they do not all return at
// once.
let pausedUntil = 0;

// Set when a gateway asks for a longer wait than MAX_WAIT. Every worker then
// stops, rather than sending the rest of the queue to a gateway that said no.
let refused = null;

// What check returns for a file it never got an answer for, because the run
// stopped.
const UNCHECKED = Symbol('unchecked');

async function check({ edition, id }) {
  const path = `${edition}/${id}${EXT}`;
  const local = await readFile(join(DIR, path)).catch(() => null);
  if (!local) return { path, why: 'no local copy to compare against' };

  for (let attempt = 1; attempt <= ATTEMPTS; attempt++) {
    const paused = pausedUntil - Date.now();
    if (paused > 0) await sleep(paused + Math.random() * 1000);
    if (refused) return UNCHECKED;
    let wait = backoff(attempt);
    try {
      const res = await fetch(`${GATEWAY}${CID}/${path}`);
      if (res.ok) {
        const remote = Buffer.from(await res.arrayBuffer());
        bytes += remote.length;
        if (sha256(remote) !== sha256(local)) {
          return { path, why: `${remote.length} bytes, contents differ` };
        }
        return null;
      }
      await res.body?.cancel();
      if (res.status === 404 || res.status === 410) {
        return { path, why: `HTTP ${res.status}` };
      }
      if (attempt === ATTEMPTS) return { path, why: `HTTP ${res.status}` };
      if (res.status === 429 || res.status === 503) {
        const asked = retryAfter(res);
        if (asked !== null && asked > MAX_WAIT) {
          refused = `HTTP ${res.status}, the gateway asks for ${Math.round(asked)}s. Try another --gateway`;
          return UNCHECKED;
        }
        if (asked !== null) wait = Math.max(asked, wait);
        pausedUntil = Math.max(pausedUntil, Date.now() + wait * 1000);
        continue;
      }
    } catch (err) {
      if (attempt === ATTEMPTS) return { path, why: err.message };
    }
    await sleep(wait * 1000);
  }
  return { path, why: 'unreachable' };
}

async function worker(queue) {
  for (;;) {
    if (refused) return;
    const job = queue.shift();
    if (!job) return;
    const bad = await check(job);
    if (bad === UNCHECKED) return;
    if (bad) failures.push(bad);
    checked += 1;
    if (checked % 250 === 0) {
      const gb = (bytes / 1e9).toFixed(2);
      process.stdout.write(
        `  ${checked}/${jobs.length}  ${failures.length} bad  ${gb} GB fetched\n`,
      );
    }
  }
}

console.log(`${jobs.length} files under ${CID}`);
console.log(`gateway ${GATEWAY}, ${JOBS} at a time\n`);

const queue = jobs.slice();
await Promise.all(Array.from({ length: JOBS }, () => worker(queue)));

// Written on every run, even empty, so a list left by an earlier run is never
// read as this one's.
if (OUT) await writeFile(OUT, failures.map((f) => `${f.path}\n`).join(''));

console.log();
if (refused) {
  console.log(
    `stopped after checking ${checked} of ${jobs.length}: ${refused}`,
  );
} else if (failures.length === 0) {
  console.log(`all ${jobs.length} files present and identical to ${DIR}`);
  process.exit(0);
}
if (failures.length === 0) process.exit(1);

console.log(`${failures.length} of the ${checked} checked failed:`);
for (const f of failures.slice(0, 40)) console.log(`  ${f.path}  ${f.why}`);
if (failures.length > 40) console.log(`  ... and ${failures.length - 40} more`);
if (OUT) console.log(`\nfull list: ${OUT}`);
process.exit(1);

#!/usr/bin/env node
// Grants the Supporter Badge after a manual review, for a donation made without
// the supporter code. There is deliberately no admin endpoint: this needs the
// owner's Cloudflare login. Check the donation in the Buy Me a Coffee dashboard
// first (docs/backend/supporters.md).
//
//   node scripts/grant-supporter.mjs RS-ABCD-2345                  # staging
//   node scripts/grant-supporter.mjs RS-ABCD-2345 --env production
//   node scripts/grant-supporter.mjs --pending [--env production]  # list requests
import { execFileSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';

const args = process.argv.slice(2);
const envAt = args.indexOf('--env');
const target = envAt >= 0 ? args[envAt + 1] : 'staging';
if (target !== 'staging' && target !== 'production') {
  console.error('--env must be staging or production');
  process.exit(1);
}
const database = target === 'production' ? 'reelish-production' : 'reelish-staging';

function run(sql) {
  execFileSync(
    'npx',
    ['wrangler', 'd1', 'execute', database, '--remote', '--env', target, '--command', sql],
    { stdio: 'inherit', shell: process.platform === 'win32' },
  );
}

if (args.includes('--pending')) {
  run(
    `SELECT support_code, datetime(claim_requested_at, 'unixepoch') AS requested
     FROM supporter_profiles
     WHERE claim_requested_at IS NOT NULL AND supporter_since IS NULL
     ORDER BY claim_requested_at`.replace(/\s+/g, ' '),
  );
  process.exit(0);
}

const code = args[0];
// The format is the only thing allowed into the SQL below.
if (!/^RS-[2-9A-HJKMNP-TV-Z]{4}-[2-9A-HJKMNP-TV-Z]{4}$/.test(code ?? '')) {
  console.error('Usage: grant-supporter.mjs RS-XXXX-XXXX [--env staging|production]');
  process.exit(1);
}
const time = Math.floor(Date.now() / 1000);
const reference = createHash('sha256').update(`manual:${randomUUID()}`).digest('base64url');
run(
  `INSERT INTO donations (provider, reference, kind, user_id, status, donated_at, received_at)
   SELECT 'manual_review', '${reference}', 'donation', user_id, 'verified', ${time}, ${time}
   FROM supporter_profiles WHERE support_code = '${code}';
   UPDATE supporter_profiles
   SET supporter_since = COALESCE(supporter_since, ${time}), claim_requested_at = NULL, updated_at = ${time}
   WHERE support_code = '${code}';`.replace(/\s+/g, ' '),
);
console.log(`Granted on ${target}. Check "changes" above: 0 means no such code.`);

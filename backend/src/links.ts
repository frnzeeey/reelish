// Reelish Connect's link resolver: the public pages every shared link opens
// (an app invitation, a title, a friend code, a watch party), and the file
// that lets Android open those links in the app.
//
// Each page is fixed: it reads nothing from D1 or a room and fetches no
// metadata, so it reveals nothing about which codes exist and costs no
// request beyond itself. Its button opens the same resource in the app
// (`reelish://…`), where every check happens as for anything typed in.
// docs/features/reelish-connect.md.

import type { Env } from './env';
import { codeAlphabet, codeLength } from './social/profiles';

/** Where the latest release's files are; the in-app updaters read the same. */
const releases = 'https://github.com/frnzeeey/reelish/releases/latest';
const downloads = {
  android: `${releases}/download/reelish.apk`,
  windows: `${releases}/download/Reelish-Setup-x64.exe`,
};

/** What a shared link names. Every kind maps to one app link. */
export type LinkTarget =
  | { kind: 'invite'; code: string | null }
  | { kind: 'title'; type: 'movie' | 'tv'; id: string }
  | { kind: 'friend'; code: string }
  | { kind: 'party'; code: string };

const shareCode = new RegExp(`^[${codeAlphabet}]{${codeLength}}$`);
const tmdbId = /^[1-9]\d{0,9}$/;
const partyCode = /^\d{8}$/;

/**
 * The target of a public link path, or null when the path is not one, or
 * names something impossible (a bad code is simply not found).
 * `invalid` marks a path of a known kind whose value is malformed.
 */
export function parseLinkPath(path: string): LinkTarget | 'invalid' | null {
  // QR codes carry links in capitals (QR's compact alphanumeric mode, so the
  // code stays small enough for its logo), so the kind is case-insensitive.
  const parts = path.split('/').filter((part) => part.length > 0);
  if (parts.length === 1 && parts[0].toLowerCase() === 'download') return { kind: 'invite', code: null };
  if (parts.length !== 2) return null;
  const kind = parts[0].toLowerCase();
  const raw = parts[1];
  let value: string;
  try {
    value = decodeURIComponent(raw);
  } catch {
    return 'invalid';
  }
  switch (kind) {
    case 'invite': {
      const code = value.toUpperCase();
      return shareCode.test(code) ? { kind: 'invite', code } : 'invalid';
    }
    case 'add': {
      const code = value.toUpperCase();
      return shareCode.test(code) ? { kind: 'friend', code } : 'invalid';
    }
    case 'movie':
    case 'tv':
      return tmdbId.test(value) ? { kind: 'title', type: kind, id: value } : 'invalid';
    case 'party':
      return partyCode.test(value) ? { kind: 'party', code: value } : 'invalid';
    default:
      return null;
  }
}

/** The app link for [target]: what the page's button opens. */
export function appLink(target: LinkTarget): string {
  switch (target.kind) {
    case 'invite':
      return target.code ? `reelish://invite/${target.code}` : 'reelish://open';
    case 'title':
      return `reelish://${target.type}/${target.id}`;
    case 'friend':
      return `reelish://add/${target.code}`;
    case 'party':
      return `reelish://party/${target.code}`;
  }
}

type Device = 'android' | 'tv' | 'windows' | 'other';

/** A best guess from the User-Agent; the page lists every option anyway. */
export function deviceOf(userAgent: string | null): Device {
  const agent = userAgent ?? '';
  if (/Android TV|GoogleTV|Google TV|AFT[A-Z]|BRAVIA|SMART-TV|SmartTV|\bTV\b/i.test(agent)) return 'tv';
  if (/Android/i.test(agent)) return 'android';
  if (/Windows NT/i.test(agent)) return 'windows';
  return 'other';
}

const escape = (value: string) =>
  value.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);

/** "1234 5678" / "ABCD EFGH": easier to read out and type. */
const spaced = (code: string) => `${code.slice(0, 4)} ${code.slice(4)}`;

function copy(target: LinkTarget): { title: string; lead: string; code?: string; open: string } {
  switch (target.kind) {
    case 'invite':
      return {
        title: 'You’re invited to Reelish',
        lead: 'Discover movies and series, share them with your people and watch together in sync, on your phone, TV or PC. Free, with no ads.',
        code: target.code ?? undefined,
        open: 'Accept in Reelish',
      };
    case 'title':
      return {
        title: target.type === 'movie' ? 'Someone shared a movie with you' : 'Someone shared a series with you',
        lead: 'Open it in Reelish to see what it’s about, save it to My list or watch it together.',
        open: 'Open in Reelish',
      };
    case 'friend':
      return {
        title: 'Add a friend on Reelish',
        lead: 'Open Reelish to send a friend request. They’ll see it in Together, and you’ll be friends once they accept.',
        code: target.code,
        open: 'Open in Reelish',
      };
    case 'party':
      return {
        title: 'You’re invited to a watch party',
        lead: 'Open the invitation in Reelish, or open Reelish, choose Join a party and enter the code. Reelish checks the party when it opens.',
        code: target.code,
        open: 'Open in Reelish',
      };
  }
}

/** The Living Room palette: warm near-black, cream text, terracotta accent. */
const style = `
:root{color-scheme:dark}
body{margin:0;min-height:100vh;display:grid;place-items:center;background:#14110E;color:#F4E9D8;
font:16px/1.55 Montserrat,"Segoe UI",system-ui,-apple-system,Roboto,sans-serif;padding:24px;box-sizing:border-box}
main{width:100%;max-width:440px;box-sizing:border-box;padding:32px 28px;border-radius:24px;background:#1F1A16;border:1px solid #39302B}
.brand{display:flex;align-items:center;gap:10px;font-weight:800;letter-spacing:.2em;font-size:13px;color:#E8B98A;margin-bottom:22px}
.mark{width:22px;height:22px;border-radius:6px;background:#D17B5B}
h1{font-size:24px;line-height:1.25;margin:0 0 10px}p{margin:0 0 18px;color:#B4AA9C}
.code{font-size:30px;font-weight:800;letter-spacing:.14em;color:#F4E9D8;background:#29221D;border-radius:14px;
padding:10px 16px;margin:0 0 20px;text-align:center;font-variant-numeric:tabular-nums}
.button{display:block;text-align:center;font-weight:800;text-decoration:none;padding:14px 20px;border-radius:14px;margin:0 0 10px}
.primary{background:#D17B5B;color:#14110E}.secondary{background:#29221D;color:#F4E9D8;border:1px solid #39302B}
h2{font-size:14px;letter-spacing:.08em;text-transform:uppercase;color:#E8B98A;margin:24px 0 10px}
ul{margin:0 0 6px;padding-left:18px;color:#B4AA9C}li{margin:0 0 6px}
.small{font-size:13px;margin:16px 0 0}
`;

function downloadSection(device: Device, target: LinkTarget): string {
  const android = `<a class="button ${device === 'android' ? 'primary' : 'secondary'}" href="${downloads.android}">Download for Android</a>`;
  const windows = `<a class="button ${device === 'windows' ? 'primary' : 'secondary'}" href="${downloads.windows}">Download for Windows</a>`;
  const tv = `<p>On Android TV or Google TV, install the Downloader app from the Play Store, open it and enter this page's Android download link: <br><strong>${escape(downloads.android)}</strong></p>`;
  const first = device === 'windows' ? windows + android : android + windows;
  const after = target.kind === 'invite' && target.code
    ? '<p class="small">After installing, come back to this page and choose Accept in Reelish, so your friend knows you joined.</p>'
    : '<p class="small">After installing, come back to this page and open it in Reelish.</p>';
  const unsupported = device === 'other'
    ? '<p>Reelish runs on Android phones and tablets, Android TV and Google TV, and Windows. Open this page on one of them to get it.</p>'
    : '';
  return `<h2>Don’t have Reelish yet?</h2>${unsupported}${device === 'tv' ? tv + first : first + '<details><summary>On a TV?</summary>' + tv + '</details>'}${after}`;
}

/** The page a shared link opens. */
export function linkPage(target: LinkTarget, userAgent: string | null): Response {
  const device = deviceOf(userAgent);
  const text = copy(target);
  const code = text.code ? `<div class="code">${escape(spaced(text.code))}</div>` : '';
  const body = `<h1>${escape(text.title)}</h1><p>${escape(text.lead)}</p>${code}
<a class="button primary" href="${escape(appLink(target))}">${escape(text.open)}</a>
${downloadSection(device, target)}
<p class="small">Reelish never hosts or sells movies or series: it plays sources each person chooses.</p>`;
  return page('Reelish', body, 200);
}

/** A known kind of link with a value that cannot be right. */
export function invalidLinkPage(): Response {
  return page(
    'Reelish · Link not valid',
    `<h1>This link isn’t valid</h1><p>Check that it was copied whole, or ask for a new one.</p>
<a class="button secondary" href="${downloads.android}">Download Reelish for Android</a>
<a class="button secondary" href="${downloads.windows}">Download Reelish for Windows</a>`,
    404,
  );
}

function page(title: string, body: string, status: number): Response {
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex"><title>${escape(title)}</title>
<style>${style}</style></head><body><main><div class="brand"><span class="mark"></span>REELISH</div>${body}</main></body></html>`;
  return new Response(html, {
    status,
    headers: {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
      'Referrer-Policy': 'no-referrer',
      'X-Frame-Options': 'DENY',
      'Strict-Transport-Security': 'max-age=31536000; includeSubDomains',
      'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
    },
  });
}

const fingerprint = /^([0-9A-F]{2}:){31}[0-9A-F]{2}$/;

/**
 * Android App Links: lets the app open this host's shared links directly.
 * Served only when ANDROID_CERT_SHA256 names the release signing
 * certificate (comma-separated for several); without it, links open the
 * page, whose button opens the app.
 */
export function assetLinks(env: Env): Response | null {
  const prints = (env.ANDROID_CERT_SHA256 ?? '')
    .split(',')
    .map((value) => value.trim().toUpperCase())
    .filter((value) => fingerprint.test(value));
  if (prints.length === 0) return null;
  return new Response(JSON.stringify([{
    relation: ['delegate_permission/common.handle_all_urls'],
    target: { namespace: 'android_app', package_name: 'io.github.frnzeeey.reelish', sha256_cert_fingerprints: prints },
  }]), {
    headers: {
      'Content-Type': 'application/json',
      'Cache-Control': 'public, max-age=3600',
      'X-Content-Type-Options': 'nosniff',
    },
  });
}

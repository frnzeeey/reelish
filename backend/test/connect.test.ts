import { describe, expect, it, vi } from 'vitest';
import { call, signIn, testEnv } from './helpers';
import { maskPath } from '../src';
import { appLink, deviceOf, parseLinkPath } from '../src/links';
import { claimWindowMs, dailyCreditLimit, normaliseInviteCode } from '../src/referrals';

const android = 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36';
const windows = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120 Safari/537.36';
const googleTv = 'Mozilla/5.0 (Linux; Android 12; Chromecast) AppleWebKit/537.36 GoogleTV Chrome/120 Safari/537.36';
const iphone = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148';

async function errorCode(response: Response): Promise<string> {
  return ((await response.json()) as { error: { code: string } }).error.code;
}

type Invites = { code: string; joined: number; invited: boolean };

async function invites(token: string): Promise<Invites> {
  const response = await call('/api/v1/referrals/me', { token });
  expect(response.status).toBe(200);
  return (await response.json()) as Invites;
}

const claim = (token: string, code: unknown) =>
  call('/api/v1/referrals/claim', { method: 'POST', token, body: { code } });

describe('shared link pages', () => {
  it('parses every kind of link, and nothing else', () => {
    expect(parseLinkPath('/invite/abcd2345')).toEqual({ kind: 'invite', code: 'ABCD2345' });
    expect(parseLinkPath('/add/ABCD2345')).toEqual({ kind: 'friend', code: 'ABCD2345' });
    expect(parseLinkPath('/movie/550')).toEqual({ kind: 'title', type: 'movie', id: '550' });
    expect(parseLinkPath('/tv/1399')).toEqual({ kind: 'title', type: 'tv', id: '1399' });
    expect(parseLinkPath('/party/12345678')).toEqual({ kind: 'party', code: '12345678' });
    expect(parseLinkPath('/download')).toEqual({ kind: 'invite', code: null });
    // As a QR code carries them: in capitals.
    expect(parseLinkPath('/INVITE/ABCD2345')).toEqual({ kind: 'invite', code: 'ABCD2345' });
    expect(parseLinkPath('/TV/1399')).toEqual({ kind: 'title', type: 'tv', id: '1399' });
    expect(parseLinkPath('/DOWNLOAD')).toEqual({ kind: 'invite', code: null });
    // Known kinds with impossible values; 0, O, 1 and I are never in codes.
    for (const path of ['/invite/ABCD0000', '/add/short', '/movie/0', '/movie/abc', '/tv/12345678901', '/party/1234']) {
      expect(parseLinkPath(path), path).toBe('invalid');
    }
    for (const path of ['/', '/movie', '/people/1', '/movie/1/2', '/api/v1/me']) {
      expect(parseLinkPath(path), path).toBeNull();
    }
    expect(appLink({ kind: 'title', type: 'tv', id: '1399' })).toBe('reelish://tv/1399');
    expect(appLink({ kind: 'invite', code: null })).toBe('reelish://open');
  });

  it('guesses the device, and every page still offers every download', async () => {
    expect(deviceOf(android)).toBe('android');
    expect(deviceOf(windows)).toBe('windows');
    expect(deviceOf(googleTv)).toBe('tv');
    expect(deviceOf(iphone)).toBe('other');
    expect(deviceOf(null)).toBe('other');

    const onWindows = await (await call('/invite/ABCD2345', { headers: { 'User-Agent': windows } })).text();
    // Windows first and highlighted; Android still there.
    expect(onWindows.indexOf('Reelish-Setup-x64.exe')).toBeLessThan(onWindows.indexOf('reelish.apk'));
    expect(onWindows).toContain('class="button primary" href="https://github.com/frnzeeey/reelish/releases/latest/download/Reelish-Setup-x64.exe"');
    const onIphone = await (await call('/invite/ABCD2345', { headers: { 'User-Agent': iphone } })).text();
    expect(onIphone).toContain('Reelish runs on Android phones and tablets, Android TV and Google TV, and Windows');
    const onTv = await (await call('/movie/550', { headers: { 'User-Agent': googleTv } })).text();
    expect(onTv).toContain('Downloader app');
  });

  it('serves fixed pages that open the app, with strict headers', async () => {
    for (const [path, link, code] of [
      ['/invite/abcd2345', 'reelish://invite/ABCD2345', 'ABCD 2345'],
      ['/add/ABCD2345', 'reelish://add/ABCD2345', 'ABCD 2345'],
      ['/movie/550', 'reelish://movie/550', null],
      ['/tv/1399', 'reelish://tv/1399', null],
      ['/party/12345678', 'reelish://party/12345678', '1234 5678'],
      ['/download', 'reelish://open', null],
    ] as const) {
      const response = await call(path, { headers: { 'User-Agent': android } });
      expect(response.status, path).toBe(200);
      expect(response.headers.get('Content-Type')).toContain('text/html');
      expect(response.headers.get('Content-Security-Policy')).toContain("default-src 'none'");
      expect(response.headers.get('Cache-Control')).toBe('no-store');
      const html = await response.text();
      expect(html, path).toContain(`href="${link}"`);
      if (code) expect(html, path).toContain(code);
      // Living Room, not the retired coral.
      expect(html).toContain('#D17B5B');
      expect(html.toLowerCase()).not.toContain('#ff4d6d');
      // Honest about what Reelish is.
      expect(html).toContain('never hosts or sells movies or series');
    }
  });

  it('pages read nothing: a code that was never issued looks like any other', async () => {
    const { session } = await signIn();
    const real = (await invites(session.accessToken)).code;
    const strip = (html: string) => html.replace(/[A-HJ-NP-Z2-9]{4} [A-HJ-NP-Z2-9]{4}|reelish:\/\/invite\/[A-Z0-9]+/g, '');
    const one = strip(await (await call(`/invite/${real}`)).text());
    const other = strip(await (await call('/invite/ZZZZ9999')).text());
    expect(one).toBe(other);
  });

  it('a malformed value gets a plain "not valid" page, never echoed back', async () => {
    const response = await call('/movie/%3Cscript%3E');
    expect(response.status).toBe(404);
    const html = await response.text();
    expect(html).toContain('This link isn’t valid');
    expect(html).not.toContain('<script>');
    // Not a link path at all: the API's JSON 404.
    const other = await call('/people/1');
    expect(other.status).toBe(404);
    expect(other.headers.get('Content-Type')).toContain('application/json');
  });

  it('the old party invitation links keep working, on the new page', async () => {
    const response = await call('/api/v1/join/12345678');
    expect(response.status).toBe(200);
    const html = await response.text();
    expect(html).toContain('href="reelish://party/12345678"');
    expect(html).toContain('#D17B5B');
  });

  it('request logs never carry a shared code or title', () => {
    expect(maskPath('/invite/ABCD2345')).toBe('/invite/:id');
    expect(maskPath('/add/ABCD2345')).toBe('/add/:id');
    expect(maskPath('/movie/550')).toBe('/movie/:id');
    expect(maskPath('/party/12345678')).toBe('/party/:id');
    expect(maskPath('/INVITE/ABCD2345')).toBe('/INVITE/:id');
  });

  it('Android App Links: served only once the signing fingerprint is set', async () => {
    const missing = await call('/.well-known/assetlinks.json');
    expect(missing.status).toBe(404);

    const print = Array.from({ length: 32 }, (_, i) => (i + 16).toString(16).toUpperCase().padStart(2, '0')).join(':');
    const saved = testEnv.ANDROID_CERT_SHA256;
    testEnv.ANDROID_CERT_SHA256 = `${print.toLowerCase()}, not-a-fingerprint`;
    try {
      const response = await call('/.well-known/assetlinks.json');
      expect(response.status).toBe(200);
      const [statement] = (await response.json()) as [{ target: { package_name: string; sha256_cert_fingerprints: string[] } }];
      expect(statement.target.package_name).toBe('io.github.frnzeeey.reelish');
      expect(statement.target.sha256_cert_fingerprints).toEqual([print]);
    } finally {
      testEnv.ANDROID_CERT_SHA256 = saved;
    }
  });
});

describe('invitations (referrals)', () => {
  it('normalises typed codes', () => {
    expect(normaliseInviteCode('abcd-2345')).toBe('ABCD2345');
    expect(normaliseInviteCode(' ABCD 2345 ')).toBe('ABCD2345');
    expect(normaliseInviteCode('ABCD0000')).toBeNull();
    expect(normaliseInviteCode(12345678)).toBeNull();
  });

  it('a code is made once, kept, and counts who joined with it', async () => {
    const inviter = await signIn();
    const first = await invites(inviter.session.accessToken);
    expect(first.code).toMatch(/^[A-HJ-NP-Z2-9]{8}$/);
    expect(first.joined).toBe(0);
    expect(first.invited).toBe(false);
    expect((await invites(inviter.session.accessToken)).code).toBe(first.code);

    const friend = await signIn();
    const credited = await claim(friend.session.accessToken, first.code.toLowerCase());
    expect(credited.status).toBe(201);
    // Again, with the same code: already done, not an error.
    expect((await claim(friend.session.accessToken, first.code)).status).toBe(200);
    expect((await invites(inviter.session.accessToken)).joined).toBe(1);
    expect((await invites(friend.session.accessToken)).invited).toBe(true);
  });

  it('never credits an account to itself, twice, or to a second inviter', async () => {
    const one = await signIn();
    const two = await signIn();
    const codeOne = (await invites(one.session.accessToken)).code;
    const codeTwo = (await invites(two.session.accessToken)).code;

    const self = await claim(one.session.accessToken, codeOne);
    expect(self.status).toBe(409);
    expect(await errorCode(self)).toBe('own_invite');

    const newcomer = await signIn();
    expect((await claim(newcomer.session.accessToken, codeOne)).status).toBe(201);
    const second = await claim(newcomer.session.accessToken, codeTwo);
    expect(second.status).toBe(409);
    expect(await errorCode(second)).toBe('already_invited');
    expect((await invites(two.session.accessToken)).joined).toBe(0);
  });

  it('unknown and malformed codes are simply not found', async () => {
    const { session } = await signIn();
    for (const code of ['ZZZZ9999', 'nope', 42, null]) {
      const response = await claim(session.accessToken, code);
      expect(response.status, String(code)).toBe(404);
      expect(await errorCode(response)).toBe('invite_not_found');
    }
  });

  it('only new accounts can be credited', async () => {
    const inviter = await signIn();
    const code = (await invites(inviter.session.accessToken)).code;
    const old = await signIn();
    const longAgo = Math.floor((Date.now() - claimWindowMs - 60_000) / 1000);
    await testEnv.DB.prepare(`UPDATE users SET created_at = ? WHERE id = ?`).bind(longAgo, old.user.id).run();
    const response = await claim(old.session.accessToken, code);
    expect(response.status).toBe(409);
    expect(await errorCode(response)).toBe('invite_too_late');
  });

  it('an inviter gains at most a day\'s limit of new accounts', async () => {
    const inviter = await signIn();
    const code = (await invites(inviter.session.accessToken)).code;
    const now = Date.now();
    const batch = [];
    for (let i = 0; i < dailyCreditLimit; i++) {
      const id = `ghost-${crypto.randomUUID()}`;
      batch.push(testEnv.DB.prepare(
        `INSERT INTO users (id, trakt_uuid, trakt_username, created_at, updated_at) VALUES (?, ?, ?, ?, ?)`,
      ).bind(id, id, id, Math.floor(now / 1000), Math.floor(now / 1000)));
      batch.push(testEnv.DB.prepare(
        `INSERT INTO referrals (referred_id, referrer_id, created_at) VALUES (?, ?, ?)`,
      ).bind(id, inviter.user.id, now));
    }
    await testEnv.DB.batch(batch);
    const spy = vi.spyOn(console, 'log').mockImplementation(() => {});
    try {
      const late = await signIn();
      const response = await claim(late.session.accessToken, code);
      expect(response.status).toBe(429);
      expect(await errorCode(response)).toBe('invite_limit');
    } finally {
      spy.mockRestore();
    }
  });

  it('deleting an account removes its code and its referrals', async () => {
    const inviter = await signIn();
    const code = (await invites(inviter.session.accessToken)).code;
    const friend = await signIn();
    expect((await claim(friend.session.accessToken, code)).status).toBe(201);
    expect((await call('/api/v1/me', { method: 'DELETE', token: inviter.session.accessToken })).status).toBeLessThan(300);
    const left = await testEnv.DB.prepare(
      `SELECT (SELECT COUNT(*) FROM referral_codes WHERE user_id = ?) + (SELECT COUNT(*) FROM referrals WHERE referrer_id = ?) AS n`,
    ).bind(inviter.user.id, inviter.user.id).first<{ n: number }>();
    expect(left?.n).toBe(0);
  });

  it('needs a signed-in account', async () => {
    expect((await call('/api/v1/referrals/me')).status).toBe(401);
    expect((await call('/api/v1/referrals/claim', { method: 'POST', body: { code: 'ABCD2345' } })).status).toBe(401);
  });
});

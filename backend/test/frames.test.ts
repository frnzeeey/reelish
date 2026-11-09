import { describe, expect, it } from 'vitest';
import { call, signIn, testEnv } from './helpers';
import { frames, isOpen, mayWear, type FrameSpec } from '../src/frames';

type FrameState = { equipped: string | null; available: string[]; collected: string[] };
type ErrorBody = { error: { code: string } };

async function makeSupporter(userId: string) {
  await testEnv.DB.prepare(
    `INSERT INTO supporter_profiles (user_id, support_code, supporter_since, created_at, updated_at)
     VALUES (?, ?, 1000, 1000, 1000)
     ON CONFLICT (user_id) DO UPDATE SET supporter_since = 1000`,
  ).bind(userId, `RS-${crypto.randomUUID().slice(0, 8)}`).run();
}

async function refund(userId: string) {
  await testEnv.DB.prepare(`UPDATE supporter_profiles SET supporter_since = NULL WHERE user_id = ?`)
    .bind(userId).run();
}

async function stateOf(token: string): Promise<FrameState> {
  const response = await call('/api/v1/me', { token });
  expect(response.status).toBe(200);
  return ((await response.json()) as { frames: FrameState }).frames;
}

const wear = (token: string, frame: string | null) =>
  call('/api/v1/me/frame', { method: 'PUT', token, body: { frame } });

const codeOf = async (response: Response) => ((await response.json()) as ErrorBody).error.code;

async function founder() {
  await testEnv.DB.prepare('DELETE FROM users WHERE trakt_uuid = ?').bind('founder-uuid').run();
  return signIn({ uuid: 'founder-uuid' });
}

const supporterFrames = frames.filter((f) => f.access === 'supporter' && !f.limited).map((f) => f.id);

describe('Avatar frames', () => {
  it('a free account wears none and can equip none, however it asks', async () => {
    const { session } = await signIn();
    const state = await stateOf(session.accessToken);
    expect(state.equipped).toBeNull();
    expect(state.available).toEqual([]);
    for (const id of ['aurora', 'founder', 'premiere_2026']) {
      const response = await wear(session.accessToken, id);
      expect(response.status).toBe(403);
    }
    expect((await stateOf(session.accessToken)).equipped).toBeNull();
  });

  it('a supporter equips any supporter frame, and it follows the account', async () => {
    const account = await signIn({ uuid: 'frames-sync' });
    await makeSupporter(account.user.id);
    const state = await stateOf(account.session.accessToken);
    for (const id of supporterFrames) expect(state.available).toContain(id);
    expect(state.available).not.toContain('founder');
    expect((await wear(account.session.accessToken, 'nebula')).status).toBe(200);
    // A second device: another session of the same account.
    const second = await signIn({ uuid: 'frames-sync' });
    expect(second.user.id).toBe(account.user.id);
    expect(second.session.sessionId).not.toBe(account.session.sessionId);
    expect((await stateOf(second.session.accessToken)).equipped).toBe('nebula');
  });

  it('a supporter cannot wear the Founder frame', async () => {
    const account = await signIn();
    await makeSupporter(account.user.id);
    const response = await wear(account.session.accessToken, 'founder');
    expect(response.status).toBe(403);
    expect(await codeOf(response)).toBe('founder_only');
  });

  it('an unknown frame is refused and an unknown stored one shows none', async () => {
    const account = await signIn();
    await makeSupporter(account.user.id);
    expect(await codeOf(await wear(account.session.accessToken, 'gilded_nope'))).toBe('unknown_frame');
    await testEnv.DB.prepare(`UPDATE users SET avatar_frame = 'retired_frame' WHERE id = ?`)
      .bind(account.user.id).run();
    expect((await stateOf(account.session.accessToken)).equipped).toBeNull();
  });

  it('when support ends the frame stops showing, and returns with it', async () => {
    const account = await signIn();
    await makeSupporter(account.user.id);
    await wear(account.session.accessToken, 'royal');
    await refund(account.user.id);
    expect((await stateOf(account.session.accessToken)).equipped).toBeNull();
    expect((await wear(account.session.accessToken, 'royal')).status).toBe(403);
    await makeSupporter(account.user.id);
    expect((await stateOf(account.session.accessToken)).equipped).toBe('royal');
  });

  it('none is always allowed, and is kept as a choice', async () => {
    const account = await founder();
    expect((await stateOf(account.session.accessToken)).equipped).toBe('founder');
    expect((await wear(account.session.accessToken, null)).status).toBe(200);
    expect((await stateOf(account.session.accessToken)).equipped).toBeNull();
  });

  it('the Founder wears the Founder frame by default and has every frame', async () => {
    const account = await founder();
    const state = await stateOf(account.session.accessToken);
    expect(state.equipped).toBe('founder');
    expect(state.available).toEqual(frames.map((frame) => frame.id));
    expect((await wear(account.session.accessToken, 'prism')).status).toBe(200);
    expect((await stateOf(account.session.accessToken)).equipped).toBe('prism');
  });

  it('wearing an open limited edition collects it', async () => {
    const account = await signIn();
    await makeSupporter(account.user.id);
    const limited = frames.find((frame) => frame.limited)!;
    if (!isOpen(limited)) return; // Outside its window this case is covered below.
    expect((await wear(account.session.accessToken, limited.id)).status).toBe(200);
    expect((await stateOf(account.session.accessToken)).collected).toContain(limited.id);
  });

  it('the frame survives signing out and in again', async () => {
    const account = await signIn({ uuid: 'frames-relogin' });
    await makeSupporter(account.user.id);
    await wear(account.session.accessToken, 'celestial');
    await call('/api/v1/auth/logout', { method: 'POST', token: account.session.accessToken });
    const again = await signIn({ uuid: 'frames-relogin' });
    expect((await stateOf(again.session.accessToken)).equipped).toBe('celestial');
  });
});

describe('Limited editions', () => {
  const limited: FrameSpec = { id: 'test_limited', access: 'supporter', limited: { from: 100, until: 200 } };

  it('can be collected only inside the window', () => {
    expect(isOpen(limited, 99)).toBe(false);
    expect(isOpen(limited, 150)).toBe(true);
    expect(isOpen(limited, 200)).toBe(false);
  });

  it('after the window, only those who collected it may wear it', () => {
    expect(mayWear(limited, 'supporter', new Set(), 250)).toBe(false);
    expect(mayWear(limited, 'supporter', new Set(['test_limited']), 250)).toBe(true);
    // Collected, but no longer a supporter: not worn.
    expect(mayWear(limited, 'free', new Set(['test_limited']), 250)).toBe(false);
    // The Founder has every frame, including any added later.
    expect(mayWear(limited, 'founder', new Set(), 250)).toBe(true);
  });

  it('a closed edition is refused to someone who never collected it', async () => {
    const account = await signIn();
    await makeSupporter(account.user.id);
    const closed = frames.find((frame) => frame.limited && !isOpen(frame));
    if (!closed) return; // Every edition is open today.
    expect(await codeOf(await wear(account.session.accessToken, closed.id))).toBe('frame_unavailable');
  });
});

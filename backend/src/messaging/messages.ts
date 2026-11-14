// The Worker's side of private messages: opening a device's connection to
// its own mailbox, and the calls other routes make into mailboxes (the
// unread count, a block, Friends turned off, an account deleted). Only
// friends with Friends on can message, checked by the mailbox at every send.
// docs/messaging/README.md.

import type { Env } from '../env';
import { log } from '../audit';
import { ApiError } from '../http';
import { requireLiveSession, type Principal } from '../sessions';
import { requireProfile } from '../social/profiles';
import { mailbox } from './mailbox';

/** GET /messages/socket: this device's connection to its own mailbox. */
export async function connectMessages(env: Env, principal: Principal, request: Request): Promise<Response> {
  if (request.headers.get('Upgrade')?.toLowerCase() !== 'websocket') {
    throw new ApiError(426, 'upgrade_required', 'Expected a WebSocket.', { Upgrade: 'websocket' });
  }
  // A signed-out or deleted account cannot connect with a still-valid token.
  await requireLiveSession(env, principal);
  await requireProfile(env, principal.userId);
  const headers = new Headers();
  for (const name of ['Upgrade', 'Connection', 'Sec-WebSocket-Key', 'Sec-WebSocket-Version', 'Sec-WebSocket-Extensions']) {
    const value = request.headers.get(name);
    if (value) headers.set(name, value);
  }
  // Built here, from the verified token: the mailbox trusts nothing a client sends.
  headers.set('X-Mailbox-User', principal.userId);
  headers.set('X-Mailbox-Session', principal.sessionId);
  try {
    return await mailbox(env, principal.userId).fetch('https://mailbox/socket', { headers });
  } catch (error) {
    log('warn', 'messages.connect_failed', { message: String(error).slice(0, 200) });
    throw new ApiError(503, 'messages_unavailable', 'Messages are unavailable right now. Try again later.');
  }
}

/** Messages this device has not received yet; nothing when the mailbox cannot answer. */
export async function pendingFor(env: Env, principal: Principal): Promise<{ count: number; from: string[] }> {
  try {
    return await mailbox(env, principal.userId).pending(principal.sessionId);
  } catch (error) {
    log('warn', 'messages.pending_failed', { message: String(error).slice(0, 200) });
    return { count: 0, from: [] };
  }
}

/** A block: nothing still waiting between the two is delivered. */
export async function purgeBetween(env: Env, one: string, other: string): Promise<void> {
  await Promise.all([
    mailbox(env, one).purgePeer(other),
    mailbox(env, other).purgePeer(one),
  ].map((call) => call.catch((error: unknown) => {
    // The block stands; a waiting message expires on its own.
    log('warn', 'messages.purge_failed', { message: String(error).slice(0, 200) });
  })));
}

/** Friends turned off or the account deleted: the mailbox is emptied. */
export async function wipeMailbox(env: Env, userId: string): Promise<void> {
  try {
    await mailbox(env, userId).wipe();
  } catch (error) {
    // Whatever is left expires on its own (messageTtlMs).
    log('warn', 'messages.wipe_failed', { message: String(error).slice(0, 200) });
  }
}

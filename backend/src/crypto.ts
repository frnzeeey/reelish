// Web Crypto helpers: random tokens, SHA-256 hashes, HMAC signatures and
// AES-GCM encryption. No custom primitives.

const encoder = new TextEncoder();

export function base64url(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function fromBase64url(text: string): Uint8Array {
  const padded = text.replace(/-/g, '+').replace(/_/g, '/');
  const binary = atob(padded + '='.repeat((4 - (padded.length % 4)) % 4));
  return Uint8Array.from(binary, (char) => char.charCodeAt(0));
}

function fromBase64(text: string): Uint8Array {
  return Uint8Array.from(atob(text), (char) => char.charCodeAt(0));
}

/** 32 random bytes as base64url: session and polling tokens. */
export function randomToken(): string {
  return base64url(crypto.getRandomValues(new Uint8Array(32)));
}

export async function sha256(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', encoder.encode(text));
  return base64url(new Uint8Array(digest));
}

/** Constant-time comparison of two strings of equal expected length. */
export function timingSafeEqual(a: string, b: string): boolean {
  const left = encoder.encode(a);
  const right = encoder.encode(b);
  if (left.length !== right.length) return false;
  let diff = 0;
  for (let i = 0; i < left.length; i++) diff |= left[i] ^ right[i];
  return diff === 0;
}

function keyBytes(secret: string, name: string): Uint8Array {
  let bytes: Uint8Array;
  try {
    bytes = fromBase64(secret);
  } catch {
    throw new Error(`${name} is not valid base64.`);
  }
  if (bytes.length < 32) throw new Error(`${name} must be at least 32 bytes.`);
  return bytes;
}

export async function hmacKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    'raw',
    keyBytes(secret, 'SESSION_SIGNING_KEY'),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign', 'verify'],
  );
}

export async function hmacSign(key: CryptoKey, data: string): Promise<string> {
  const signature = await crypto.subtle.sign('HMAC', key, encoder.encode(data));
  return base64url(new Uint8Array(signature));
}

export async function hmacVerify(
  key: CryptoKey,
  data: string,
  signature: string,
): Promise<boolean> {
  let bytes: Uint8Array;
  try {
    bytes = fromBase64url(signature);
  } catch {
    return false;
  }
  return crypto.subtle.verify('HMAC', key, bytes, encoder.encode(data));
}

async function aesKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    'raw',
    keyBytes(secret, 'TOKEN_ENCRYPTION_KEY').slice(0, 32),
    'AES-GCM',
    false,
    ['encrypt', 'decrypt'],
  );
}

/** AES-256-GCM with a random 96-bit IV; `aad` binds the value to its row. */
export async function encrypt(
  secret: string,
  plaintext: string,
  aad: string,
): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const sealed = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv, additionalData: encoder.encode(aad) },
    await aesKey(secret),
    encoder.encode(plaintext),
  );
  return `v1.${base64url(iv)}.${base64url(new Uint8Array(sealed))}`;
}

export async function decrypt(
  secret: string,
  sealed: string,
  aad: string,
): Promise<string> {
  const [version, iv, data] = sealed.split('.');
  if (version !== 'v1' || !iv || !data) throw new Error('Unknown ciphertext.');
  const plain = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: fromBase64url(iv), additionalData: encoder.encode(aad) },
    await aesKey(secret),
    fromBase64url(data),
  );
  return new TextDecoder().decode(plain);
}

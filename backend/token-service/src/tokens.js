/**
 * The small cryptographic pieces accounts are built from: signed access
 * tokens, refresh tokens, sign-in codes, and the hashes they are stored as.
 * Node's own crypto only — no dependency to keep patched.
 */
import { createHash, createHmac, randomBytes, randomInt, timingSafeEqual } from 'node:crypto';

const b64 = (value) => Buffer.from(value).toString('base64url');

/** HS256 JWT. `ttlSeconds` from `nowMs`. */
export function signJwt(payload, secret, ttlSeconds, nowMs = Date.now()) {
  const iat = Math.floor(nowMs / 1000);
  const head = b64(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const body = b64(JSON.stringify({ ...payload, iat, exp: iat + ttlSeconds }));
  const signature = createHmac('sha256', secret).update(`${head}.${body}`).digest('base64url');
  return `${head}.${body}.${signature}`;
}

/**
 * Returns `{ ok: true, payload }`, or `{ ok: false, code }` with
 * `token_expired` (refresh and retry) or `token_invalid` (sign in again).
 */
export function verifyJwt(token, secret, nowMs = Date.now()) {
  if (typeof token !== 'string') return { ok: false, code: 'token_invalid' };
  const parts = token.split('.');
  if (parts.length !== 3) return { ok: false, code: 'token_invalid' };
  const [head, body, signature] = parts;
  const expected = createHmac('sha256', secret).update(`${head}.${body}`).digest('base64url');
  if (!safeEqual(signature, expected)) return { ok: false, code: 'token_invalid' };
  let payload;
  try {
    // The algorithm is fixed here; whatever the header claims is ignored.
    payload = JSON.parse(Buffer.from(body, 'base64url').toString('utf8'));
  } catch {
    return { ok: false, code: 'token_invalid' };
  }
  if (typeof payload.exp !== 'number') return { ok: false, code: 'token_invalid' };
  if (payload.exp * 1000 <= nowMs) return { ok: false, code: 'token_expired' };
  return { ok: true, payload };
}

/** Constant-time string comparison. */
export function safeEqual(a, b) {
  const left = Buffer.from(String(a));
  const right = Buffer.from(String(b));
  if (left.length !== right.length) return false;
  return timingSafeEqual(left, right);
}

export const sha256 = (value) => createHash('sha256').update(String(value)).digest('hex');
export const hmac = (secret, value) => createHmac('sha256', secret).update(String(value)).digest('hex');

/** 256 random bits; only its hash is ever stored. */
export const newRefreshToken = () => randomBytes(32).toString('base64url');

/** A six-digit sign-in code, uniformly random. */
export const newCode = () => String(randomInt(0, 1_000_000)).padStart(6, '0');

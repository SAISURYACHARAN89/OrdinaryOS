/**
 * Accounts, ownership and daily credits.
 *
 * Who may use Ordinary is decided here, on the server, from the store's own
 * order records (read only) plus two small lists the team controls:
 *   - `grants`:  people let in, or given unlimited use, by hand
 *   - `revoked`: people or orders whose access was taken away by hand
 *
 * Everything takes its databases, clock and mailer as arguments so it can be
 * tested against an in-memory MongoDB with a controllable clock.
 */
import { ObjectId } from 'mongodb';
import { hmac, newCode, newRefreshToken, safeEqual, sha256, signJwt, verifyJwt } from './tokens.js';

export class HttpError extends Error {
  constructor(status, body) {
    super(body?.error ?? body?.code ?? `HTTP ${status}`);
    this.status = status;
    this.body = body;
  }
}

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

export const DEFAULTS = {
  dailyCredits: 25,
  // Ceilings a modified app cannot get past, whatever it reports. A session is
  // released after a quiet minute and opened again at the next sound, so a
  // busy day can need one a minute; these sit just above that.
  mintsPerDayFree: 1500,
  mintsPerDayUnlimited: 3000,
  maxDevices: 2,
  // The App Review sign-in: off unless an email and a code are configured.
  reviewEmail: '',
  reviewCode: '',
  reviewTier: 'unlimited',
  reviewTriesPerHour: 40,
  accessTtlSeconds: 15 * 60,
  refreshTtlMs: 90 * DAY,
  // A refresh whose reply was lost may be retried with the old token this long.
  refreshGraceMs: 60_000,
  codeTtlMs: 10 * MINUTE,
  codeAttempts: 5,
  resendCooldownMs: 60_000,
  sendsPerHourPerEmail: 5,
  sendsPerHourPerIp: 20,
  entitlementCacheMs: 10 * MINUTE,
  defaultTz: 'Asia/Kolkata',
};

export const normEmail = (value) => String(value ?? '').trim().toLowerCase();
const EMAIL = /^[^\s@]{1,64}@[^\s@]{1,190}\.[^\s@]{2,}$/;

function validTz(tz, fallback) {
  try {
    new Intl.DateTimeFormat('en-CA', { timeZone: tz });
    return tz;
  } catch {
    return fallback;
  }
}

/** The calendar date in `tz` at `at`, as YYYY-MM-DD. */
export function dayKey(tz, at) {
  return new Intl.DateTimeFormat('en-CA', { timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit' }).format(at);
}

/** The next local midnight in `tz` after `at`. */
export function nextMidnight(tz, at) {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat('en-US', {
      timeZone: tz, hourCycle: 'h23', year: 'numeric', month: 'numeric', day: 'numeric',
      hour: 'numeric', minute: 'numeric', second: 'numeric',
    }).formatToParts(at).filter((p) => p.type !== 'literal').map((p) => [p.type, Number(p.value)]),
  );
  const localAsUtc = Date.UTC(parts.year, parts.month - 1, parts.day, parts.hour, parts.minute, parts.second);
  const offset = localAsUtc - Math.floor(at.getTime() / 1000) * 1000;
  return new Date(Date.UTC(parts.year, parts.month - 1, parts.day + 1) - offset);
}

/**
 * The indexes the account collections rely on — the unique ones are what make
 * sign-in and credit counting safe under concurrency. Creating an index that
 * already exists is a no-op, so this is safe to call at every start.
 */
export async function ensureIndexes(ordinary) {
  const index = (name, key, options = {}) => ordinary.collection(name).createIndex(key, options);
  await Promise.all([
    index('accounts', { email: 1 }, { unique: true }),
    index('accounts', { storeUserId: 1 }),
    index('devices', { accountId: 1, installId: 1 }, { unique: true }),
    index('devices', { accountId: 1, revokedAt: 1 }),
    index('devices', { refreshHash: 1 }),
    index('otp', { emailHash: 1 }, { unique: true }),
    index('otp', { expiresAt: 1 }, { expireAfterSeconds: 0 }),
    index('usage_days', { accountId: 1, day: 1 }, { unique: true }),
    index('usage_events', { exchangeId: 1 }, { unique: true }),
    index('usage_events', { at: 1 }, { expireAfterSeconds: 90 * 24 * 3600 }),
    index('revoked', { email: 1 }),
    index('revoked', { orderId: 1 }),
    index('grants', { email: 1 }, { unique: true }),
    index('ratelimits', { key: 1, windowStart: 1 }, { unique: true }),
    index('ratelimits', { expiresAt: 1 }, { expireAfterSeconds: 0 }),
  ]);
}

export function createAccounts({ store, ordinary, mailer, secrets, config = {}, clock = () => new Date() }) {
  const cfg = { ...DEFAULTS, ...config };
  if (!secrets?.jwt || !secrets?.otp) throw new Error('JWT_SECRET and OTP_HMAC_SECRET are required.');

  const accounts = ordinary.collection('accounts');
  const devices = ordinary.collection('devices');
  const otp = ordinary.collection('otp');
  const usageDays = ordinary.collection('usage_days');
  const usageEvents = ordinary.collection('usage_events');
  const grants = ordinary.collection('grants');
  const revoked = ordinary.collection('revoked');
  const ratelimits = ordinary.collection('ratelimits');

  const isDuplicate = (error) => error?.code === 11000;

  // ---------------------------------------------------------- store review

  // App Review has to sign in, and a reviewer cannot read a code sent to
  // someone's inbox. One address, set in configuration, signs in with a
  // fixed code instead: no mail is sent, and it is treated as an owner. It
  // exists only when both are configured, the code is checked like any
  // other, guesses are limited, and `access.mjs revoke` shuts it at once.
  const reviewEmail = cfg.reviewEmail ? normEmail(cfg.reviewEmail) : '';
  const reviewCode = String(cfg.reviewCode ?? '').trim();
  const isReview = (email) =>
    reviewEmail !== '' && reviewCode.length >= 6 && email === reviewEmail;

  // ------------------------------------------------------------ rate limits

  /** Counts one hit in the current window; true when over `limit`. */
  async function overLimit(key, limit, windowMs) {
    const now = clock();
    const windowStart = new Date(Math.floor(now.getTime() / windowMs) * windowMs);
    const update = { $inc: { count: 1 }, $setOnInsert: { expiresAt: new Date(windowStart.getTime() + windowMs * 2) } };
    let doc;
    try {
      doc = await ratelimits.findOneAndUpdate({ key, windowStart }, update, { upsert: true, returnDocument: 'after' });
    } catch (error) {
      if (!isDuplicate(error)) throw error;
      doc = await ratelimits.findOneAndUpdate({ key, windowStart }, update, { returnDocument: 'after' });
    }
    return (doc?.count ?? 1) > limit;
  }

  // ------------------------------------------------------------ entitlement

  /**
   * What this email is allowed: `unlimited`, `free` (the daily allowance), or
   * `none` with a reason. Computed from scratch; see [currentEntitlement] for
   * the cached form.
   */
  async function entitlementFor(emailRaw) {
    const email = normEmail(emailRaw);
    const now = clock();

    if (await revoked.findOne({ email, orderId: null })) return { tier: 'none', reason: 'revoked' };
    if (isReview(email)) {
      return { tier: cfg.reviewTier, reason: 'review', until: null, storeUserId: null, name: 'App Review' };
    }

    const grant = await grants.findOne({ email });
    const grantLive = grant && (!grant.until || grant.until > now);

    // The store saves emails as typed, so match without regard to case.
    const users = await store.collection('users')
      .find({ email }, { collation: { locale: 'en', strength: 2 }, projection: { _id: 1, name: 1 } })
      .toArray();
    let owner = false;
    if (users.length) {
      const orders = await store.collection('orders')
        .find({ user: { $in: users.map((u) => u._id) }, status: 'active' }, { projection: { _id: 1 } })
        .toArray();
      if (orders.length) {
        const pulled = await revoked.find({ orderId: { $in: orders.map((o) => String(o._id)) } }).toArray();
        const gone = new Set(pulled.map((r) => r.orderId));
        owner = orders.some((o) => !gone.has(String(o._id)));
      }
    }

    const base = { storeUserId: users[0]?._id ?? null, name: users[0]?.name ?? null };
    if (grantLive && grant.tier === 'unlimited') return { tier: 'unlimited', reason: 'grant', until: grant.until ?? null, ...base };
    if (owner) return { tier: 'free', reason: 'owner', ...base };
    if (grantLive) return { tier: 'free', reason: 'grant', until: grant.until ?? null, ...base };
    return { tier: 'none', reason: 'no_purchase', ...base };
  }

  /** The account's entitlement, re-checked against the store every few minutes. */
  async function currentEntitlement(account, { fresh = false } = {}) {
    if (account.status === 'blocked') return { tier: 'none', reason: 'blocked' };
    const cached = account.ent;
    const now = clock();
    if (!fresh && cached?.at && now - cached.at < cfg.entitlementCacheMs) return cached;
    const ent = await entitlementFor(account.email);
    const saved = { tier: ent.tier, reason: ent.reason, until: ent.until ?? null, at: now };
    await accounts.updateOne({ _id: account._id }, { $set: { ent: saved } });
    account.ent = saved;
    return saved;
  }

  // ---------------------------------------------------------------- credits

  async function usageToday(account) {
    const day = dayKey(account.tz, clock());
    const doc = await usageDays.findOne({ accountId: account._id, day });
    return { day, answers: doc?.answers ?? 0, mints: doc?.mints ?? 0 };
  }

  /** Adds one to `field` unless it has reached `cap`. Atomic across phones. */
  async function bump(account, field, cap) {
    const day = dayKey(account.tz, clock());
    const key = { accountId: account._id, day };
    try {
      await usageDays.updateOne(key, { $setOnInsert: { answers: 0, mints: 0, createdAt: clock() } }, { upsert: true });
    } catch (error) {
      if (!isDuplicate(error)) throw error;
    }
    const filter = cap == null ? key : { ...key, [field]: { $lt: cap } };
    const result = await usageDays.updateOne(filter, { $inc: { [field]: 1 } });
    return result.modifiedCount === 1;
  }

  async function credits(account, ent) {
    const used = await usageToday(account);
    const unlimited = ent.tier === 'unlimited';
    return {
      tier: ent.tier,
      dailyLimit: unlimited ? null : cfg.dailyCredits,
      creditsLeft: unlimited ? null : Math.max(0, cfg.dailyCredits - used.answers),
      usedToday: used.answers,
      resetsAt: nextMidnight(account.tz, clock()).toISOString(),
      unlimitedUntil: unlimited ? (ent.until ?? null) : null,
    };
  }

  // ---------------------------------------------------------------- sign-in

  /**
   * Starts sign-in. The reply never says whether the email is a customer:
   * owners get a code, anyone else gets a "no purchase found" email at most
   * once a day.
   */
  async function start({ email: emailRaw, ip }) {
    const email = normEmail(emailRaw);
    if (!EMAIL.test(email)) throw new HttpError(400, { code: 'bad_email', error: 'Enter a valid email address.' });

    if (ip && (await overLimit(`ip:${ip}`, cfg.sendsPerHourPerIp, HOUR))) {
      throw new HttpError(429, { code: 'slow_down', error: 'Too many attempts. Try again in an hour.' });
    }
    // Nothing to send: this address signs in with its configured code.
    if (isReview(email)) return { ok: true };

    const now = clock();
    const emailHash = hmac(secrets.otp, email);
    const existing = await otp.findOne({ emailHash });
    if (existing?.lastSentAt && now - existing.lastSentAt < cfg.resendCooldownMs) {
      // Asked again too soon: the code already sent is still the one to use.
      return { ok: true };
    }
    if (await overLimit(`email:${emailHash}`, cfg.sendsPerHourPerEmail, HOUR)) {
      throw new HttpError(429, { code: 'slow_down', error: 'Too many codes requested. Try again in an hour.' });
    }

    const ent = await entitlementFor(email);
    if (ent.tier === 'none') {
      if (!(await overLimit(`nopurchase:${emailHash}`, 1, DAY))) {
        await mailer.sendNoPurchase(email).catch((error) => console.warn('[auth] no-purchase mail failed:', error.message));
      }
      return { ok: true };
    }

    const code = newCode();
    await otp.updateOne(
      { emailHash },
      { $set: { codeHmac: hmac(secrets.otp, `${email}|${code}`), attempts: 0, expiresAt: new Date(now.getTime() + cfg.codeTtlMs), lastSentAt: now } },
      { upsert: true },
    );
    try {
      await mailer.sendCode(email, code);
    } catch (error) {
      await otp.deleteOne({ emailHash });
      throw new HttpError(503, { code: error.code ?? 'mail_failed', error: 'We could not send the code. Try again in a moment.' });
    }
    return { ok: true };
  }

  const publicDevice = (d, currentId) => ({
    id: String(d._id),
    name: d.name,
    platform: d.platform,
    lastSeenAt: d.lastSeenAt?.toISOString?.() ?? null,
    current: currentId ? String(d._id) === String(currentId) : false,
  });

  async function issue(account, device, ent) {
    const now = clock();
    const refreshToken = newRefreshToken();
    await devices.updateOne(
      { _id: device._id },
      { $set: { refreshHash: sha256(refreshToken), prevRefreshHash: null, rotatedAt: now, refreshExpiresAt: new Date(now.getTime() + cfg.refreshTtlMs), lastSeenAt: now, revokedAt: null } },
    );
    return {
      accessToken: signJwt({ sub: String(account._id), did: String(device._id), tier: ent.tier }, secrets.jwt, cfg.accessTtlSeconds, now.getTime()),
      refreshToken,
      expiresInSeconds: cfg.accessTtlSeconds,
    };
  }

  /**
   * Finishes sign-in with the emailed code — or, when a third phone had to
   * pick one to sign out, with the short-lived `ticket` that reply carried.
   */
  async function verify({ email: emailRaw, code, ticket, installId, deviceName, platform, tz, replaceDeviceId }) {
    const now = clock();
    let email = normEmail(emailRaw);
    if (typeof installId !== 'string' || installId.length < 16 || installId.length > 80) {
      throw new HttpError(400, { code: 'bad_request', error: 'installId is required.' });
    }

    if (ticket) {
      const checked = verifyJwt(ticket, secrets.jwt, now.getTime());
      if (!checked.ok || checked.payload.purpose !== 'device_swap' || checked.payload.installId !== installId) {
        throw new HttpError(401, { code: 'bad_code', error: 'That took too long. Ask for a new code.' });
      }
      email = checked.payload.email;
    } else if (isReview(email)) {
      // A fixed code can be guessed at leisure unless tries are counted. A
      // few dozen an hour is plenty for a reviewer and useless to a guesser.
      if (await overLimit('review:verify', cfg.reviewTriesPerHour, HOUR)) {
        throw new HttpError(429, { code: 'code_locked', error: 'Too many tries. Try again in an hour.' });
      }
      const given = hmac(secrets.otp, `review|${String(code ?? '').trim()}`);
      if (!safeEqual(given, hmac(secrets.otp, `review|${reviewCode}`))) {
        throw new HttpError(401, { code: 'bad_code', error: 'That code is not right.' });
      }
    } else {
      const emailHash = hmac(secrets.otp, email);
      const entry = await otp.findOne({ emailHash });
      if (!entry || entry.expiresAt <= now) {
        throw new HttpError(401, { code: 'code_expired', error: 'That code has expired. Ask for a new one.' });
      }
      if (entry.attempts >= cfg.codeAttempts) {
        throw new HttpError(429, { code: 'code_locked', error: 'Too many wrong tries. Ask for a new code.' });
      }
      const given = hmac(secrets.otp, `${email}|${String(code ?? '').trim()}`);
      if (!safeEqual(given, entry.codeHmac)) {
        await otp.updateOne({ emailHash }, { $inc: { attempts: 1 } });
        const left = Math.max(0, cfg.codeAttempts - entry.attempts - 1);
        throw new HttpError(401, { code: 'bad_code', error: 'That code is not right.', attemptsLeft: left });
      }
      // One use only.
      await otp.deleteOne({ emailHash });
    }

    const ent = await entitlementFor(email);
    if (ent.tier === 'none') throw new HttpError(403, { code: ent.reason, error: 'No Ordinary purchase found for this email.' });

    const zone = validTz(tz, cfg.defaultTz);
    let account = await accounts.findOne({ email });
    if (account?.status === 'blocked') throw new HttpError(403, { code: 'blocked', error: 'This account is blocked.' });
    const entSaved = { tier: ent.tier, reason: ent.reason, until: ent.until ?? null, at: now };
    if (!account) {
      try {
        const inserted = await accounts.insertOne({
          email, storeUserId: ent.storeUserId, name: ent.name, tz: zone, status: 'active', createdAt: now, lastSignInAt: now, ent: entSaved,
        });
        account = await accounts.findOne({ _id: inserted.insertedId });
      } catch (error) {
        if (!isDuplicate(error)) throw error;
        account = await accounts.findOne({ email });
      }
    }
    await accounts.updateOne({ _id: account._id }, { $set: { lastSignInAt: now, tz: zone, ent: entSaved, name: ent.name ?? account.name ?? null, storeUserId: ent.storeUserId ?? account.storeUserId ?? null } });
    account = { ...account, tz: zone, ent: entSaved };

    const active = await devices.find({ accountId: account._id, revokedAt: null }).toArray();
    let device = active.find((d) => d.installId === installId);
    if (!device) {
      if (active.length >= cfg.maxDevices) {
        let victim = replaceDeviceId && active.find((d) => String(d._id) === String(replaceDeviceId));
        // Reviewers come and go on different devices and cannot be asked
        // which of a stranger's phones to sign out: the stalest one goes.
        if (!victim && isReview(email)) {
          victim = [...active].sort((a, b) => (a.lastSeenAt ?? 0) - (b.lastSeenAt ?? 0))[0];
        }
        if (!victim) {
          throw new HttpError(409, {
            code: 'device_limit',
            error: `Ordinary is already on ${cfg.maxDevices} phones.`,
            devices: active.map((d) => publicDevice(d)),
            ticket: signJwt({ purpose: 'device_swap', email, installId }, secrets.jwt, 10 * 60, now.getTime()),
          });
        }
        await devices.updateOne({ _id: victim._id }, { $set: { revokedAt: now, refreshHash: null, prevRefreshHash: null } });
      }
      const name = String(deviceName ?? 'Phone').slice(0, 60);
      const os = ['ios', 'android'].includes(platform) ? platform : 'other';
      // The same phone signing in again reuses its row (one per install).
      await devices.updateOne(
        { accountId: account._id, installId },
        { $set: { name, platform: os, revokedAt: null, lastSeenAt: now }, $setOnInsert: { createdAt: now } },
        { upsert: true },
      );
      device = await devices.findOne({ accountId: account._id, installId });
    }

    const tokens = await issue(account, device, ent);
    return { ...tokens, ...(await describe(account, device, entSaved)) };
  }

  /** Swaps a refresh token for a new pair. Every refresh token works once. */
  async function refresh({ refreshToken, installId }) {
    const now = clock();
    const signedOut = () => new HttpError(401, { code: 'signed_out', error: 'Please sign in again.' });
    if (typeof refreshToken !== 'string' || !refreshToken) throw signedOut();
    const hash = sha256(refreshToken);
    let device = await devices.findOne({ refreshHash: hash });
    let reused = false;
    if (!device) {
      device = await devices.findOne({ prevRefreshHash: hash });
      reused = Boolean(device);
    }
    if (!device || device.revokedAt || device.installId !== installId) throw signedOut();
    if (!device.refreshExpiresAt || device.refreshExpiresAt <= now) throw signedOut();
    if (reused && now - device.rotatedAt > cfg.refreshGraceMs) {
      // An old token turning up later means it was copied. Sign that phone out.
      await devices.updateOne({ _id: device._id }, { $set: { revokedAt: now, refreshHash: null, prevRefreshHash: null } });
      throw signedOut();
    }
    const account = await accounts.findOne({ _id: device.accountId });
    if (!account || account.status === 'blocked') throw signedOut();
    const ent = await currentEntitlement(account, { fresh: true });

    const next = newRefreshToken();
    await devices.updateOne(
      { _id: device._id },
      { $set: { refreshHash: sha256(next), prevRefreshHash: hash, rotatedAt: now, refreshExpiresAt: new Date(now.getTime() + cfg.refreshTtlMs), lastSeenAt: now } },
    );
    return {
      accessToken: signJwt({ sub: String(account._id), did: String(device._id), tier: ent.tier }, secrets.jwt, cfg.accessTtlSeconds, now.getTime()),
      refreshToken: next,
      expiresInSeconds: cfg.accessTtlSeconds,
      ...(await describe(account, device, ent)),
    };
  }

  /** Resolves a Bearer token to its account and phone, or throws 401. */
  async function authenticate(header) {
    const token = typeof header === 'string' && header.startsWith('Bearer ') ? header.slice(7) : null;
    const checked = verifyJwt(token, secrets.jwt, clock().getTime());
    if (!checked.ok) throw new HttpError(401, { code: checked.code, error: 'Sign-in needed.' });
    let accountId; let deviceId;
    try {
      accountId = new ObjectId(checked.payload.sub);
      deviceId = new ObjectId(checked.payload.did);
    } catch {
      throw new HttpError(401, { code: 'token_invalid', error: 'Sign-in needed.' });
    }
    const [account, device] = await Promise.all([accounts.findOne({ _id: accountId }), devices.findOne({ _id: deviceId })]);
    if (!account || !device || device.revokedAt || String(device.accountId) !== String(account._id)) {
      throw new HttpError(401, { code: 'signed_out', error: 'Please sign in again.' });
    }
    return { account, device };
  }

  async function describe(account, device, ent) {
    const list = await devices.find({ accountId: account._id, revokedAt: null }).sort({ createdAt: 1 }).toArray();
    return {
      account: { email: account.email, name: account.name ?? null },
      entitlement: { tier: ent.tier, reason: ent.reason },
      credits: ent.tier === 'none' ? null : await credits(account, ent),
      devices: list.map((d) => publicDevice(d, device._id)),
    };
  }

  async function me({ account, device }) {
    const ent = await currentEntitlement(account);
    return describe(account, device, ent);
  }

  async function signOut({ device }) {
    await devices.updateOne({ _id: device._id }, { $set: { revokedAt: clock(), refreshHash: null, prevRefreshHash: null } });
    return { ok: true };
  }

  async function removeDevice({ account }, deviceId) {
    let id;
    try { id = new ObjectId(String(deviceId)); } catch { throw new HttpError(400, { code: 'bad_request', error: 'Unknown phone.' }); }
    const result = await devices.updateOne(
      { _id: id, accountId: account._id, revokedAt: null },
      { $set: { revokedAt: clock(), refreshHash: null, prevRefreshHash: null } },
    );
    if (!result.matchedCount) throw new HttpError(404, { code: 'not_found', error: 'Unknown phone.' });
    return { ok: true };
  }

  /** Erases Ordinary's own record of this person. Store data is not ours to touch. */
  async function deleteAccount({ account }) {
    await devices.deleteMany({ accountId: account._id });
    await usageDays.deleteMany({ accountId: account._id });
    await usageEvents.deleteMany({ accountId: account._id });
    await accounts.deleteOne({ _id: account._id });
    return { ok: true };
  }

  // ------------------------------------------------------- sessions & usage

  /**
   * Decides whether this account may open a Gemini session right now, and
   * counts it. Throws 403 (no access), 402 (today's credits are used up) or
   * 429 (far too many sessions today).
   */
  async function authorizeSession({ account }) {
    const ent = await currentEntitlement(account);
    if (ent.tier === 'none') throw new HttpError(403, { code: ent.reason, error: 'Ordinary is for Ordinary owners.' });
    const snapshot = await credits(account, ent);
    if (ent.tier === 'free' && snapshot.creditsLeft <= 0) {
      throw new HttpError(402, { code: 'out_of_credits', error: 'Daily limit reached.', ...snapshot });
    }
    const cap = ent.tier === 'unlimited' ? cfg.mintsPerDayUnlimited : cfg.mintsPerDayFree;
    if (!(await bump(account, 'mints', cap))) {
      throw new HttpError(429, { code: 'too_many_sessions', error: 'Too many sessions today. Try again tomorrow.', ...snapshot });
    }
    return snapshot;
  }

  /**
   * Charges one credit for an answer Ordinary gave. `exchangeId` makes it
   * idempotent: the app may report the same answer twice (a retry) and is
   * charged once.
   */
  async function recordAnswer({ account, device }, exchangeId) {
    if (typeof exchangeId !== 'string' || !/^[A-Za-z0-9-]{8,64}$/.test(exchangeId)) {
      throw new HttpError(400, { code: 'bad_request', error: 'exchangeId is required.' });
    }
    const ent = await currentEntitlement(account);
    if (ent.tier === 'none') throw new HttpError(403, { code: ent.reason, error: 'Ordinary is for Ordinary owners.' });
    let counted = true;
    try {
      await usageEvents.insertOne({ exchangeId: `${account._id}:${exchangeId}`, accountId: account._id, installId: device.installId, at: clock() });
    } catch (error) {
      if (!isDuplicate(error)) throw error;
      counted = false;
    }
    if (counted) await bump(account, 'answers', ent.tier === 'unlimited' ? null : cfg.dailyCredits);
    return { counted, ...(await credits(account, ent)) };
  }

  // ------------------------------------------------------------------ admin

  const admin = {
    /** Lets someone in by hand, or gives them unlimited use. `until` optional. */
    async grant(email, tier, { until = null, note = '' } = {}) {
      if (!['free', 'unlimited'].includes(tier)) throw new Error('tier must be free or unlimited');
      const e = normEmail(email);
      await grants.updateOne({ email: e }, { $set: { tier, until, note, at: clock() } }, { upsert: true });
      await accounts.updateOne({ email: e }, { $unset: { ent: '' } });
    },
    async ungrant(email) {
      const e = normEmail(email);
      await grants.deleteOne({ email: e });
      await accounts.updateOne({ email: e }, { $unset: { ent: '' } });
    },
    /** Takes access away: by email (the person) or by store order id. */
    async revoke(target, reason = '') {
      const byEmail = String(target).includes('@');
      const doc = byEmail ? { email: normEmail(target), orderId: null } : { email: null, orderId: String(target) };
      await revoked.updateOne(doc, { $set: { reason, at: clock() } }, { upsert: true });
      if (byEmail) await accounts.updateOne({ email: doc.email }, { $unset: { ent: '' } });
      else await accounts.updateMany({}, { $unset: { ent: '' } });
    },
    async unrevoke(target) {
      const byEmail = String(target).includes('@');
      await revoked.deleteOne(byEmail ? { email: normEmail(target), orderId: null } : { orderId: String(target) });
      await accounts.updateMany(byEmail ? { email: normEmail(target) } : {}, { $unset: { ent: '' } });
    },
    entitlementFor,
  };

  return { start, verify, refresh, authenticate, me, signOut, removeDevice, deleteAccount, authorizeSession, recordAnswer, entitlementFor, admin };
}

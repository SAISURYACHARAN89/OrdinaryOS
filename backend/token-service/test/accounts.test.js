/**
 * Accounts, ownership and credits, against a real (in-memory) MongoDB with a
 * controllable clock and a mailer that captures instead of sending.
 *
 *   npm test
 */
import assert from 'node:assert/strict';
import { after, before, beforeEach, describe, it } from 'node:test';
import { MongoClient, ObjectId } from 'mongodb';
import { MongoMemoryServer } from 'mongodb-memory-server';
import { createAccounts, dayKey, ensureIndexes, HttpError, nextMidnight } from '../src/accounts.js';
import { signJwt, verifyJwt } from '../src/tokens.js';

let mongod; let client; let store; let ordinary;
let now; let sent; let api;

const clock = () => new Date(now);
const advance = (ms) => { now += ms; };
const MIN = 60_000; const HOUR = 60 * MIN; const DAY = 24 * HOUR;
const installA = 'install-aaaaaaaaaaaaaaaa';
const installB = 'install-bbbbbbbbbbbbbbbb';
const installC = 'install-cccccccccccccccc';

const mailer = {
  sendCode: async (to, code) => { sent.push({ to, code }); },
  sendNoPurchase: async (to) => { sent.push({ to, noPurchase: true }); },
};
const lastCode = (email) => sent.filter((m) => m.to === email && m.code).at(-1)?.code;

async function fails(promise, status, code) {
  await assert.rejects(promise, (error) => {
    assert.ok(error instanceof HttpError, `expected HttpError, got ${error}`);
    assert.equal(error.status, status);
    if (code) assert.equal(error.body.code, code);
    return true;
  });
}

async function signIn(email, installId = installA, extra = {}) {
  await api.start({ email, ip: '1.1.1.1' });
  return api.verify({ email, code: lastCode(email.trim().toLowerCase()), installId, deviceName: 'Test phone', platform: 'ios', tz: 'Asia/Kolkata', ...extra });
}
const bearer = (session) => `Bearer ${session.accessToken}`;

async function addCustomer(email, { status = 'active', paymentMethod = 'online' } = {}) {
  const user = await store.collection('users').insertOne({ name: 'Test Buyer', email, mobile: '0000000000', createdAt: clock() });
  const order = status
    ? await store.collection('orders').insertOne({ user: user.insertedId, plan: new ObjectId(), paymentMethod, amount: 1, status, createdAt: clock() })
    : null;
  return { userId: user.insertedId, orderId: order?.insertedId };
}

before(async () => {
  mongod = await MongoMemoryServer.create();
  client = await MongoClient.connect(mongod.getUri());
});
after(async () => {
  await client?.close();
  await mongod?.stop();
});

beforeEach(async () => {
  store = client.db('store_t');
  ordinary = client.db('ord_t');
  await store.dropDatabase();
  await ordinary.dropDatabase();
  await ensureIndexes(ordinary);
  now = Date.parse('2026-10-05T06:00:00Z'); // 11:30 in India
  sent = [];
  api = createAccounts({ store, ordinary, mailer, secrets: { jwt: 'jwt-secret', otp: 'otp-secret' }, clock });
});

describe('the listening allowance', () => {
  const heard = (session, batchId, count) => api.authenticate(bearer(session)).then((auth) => api.recordHeard(auth, batchId, count));

  it('counts sentences heard in batches, once each, and reports what is left', async () => {
    await addCustomer('owner@x.com');
    const session = await signIn('owner@x.com');
    let reply = await heard(session, 'batch-00000001', 10);
    assert.equal(reply.counted, true);
    assert.equal(reply.heardLimit, 150);
    assert.equal(reply.heardLeft, 140);
    // The same report again, after a lost reply, is not counted twice.
    reply = await heard(session, 'batch-00000001', 10);
    assert.equal(reply.counted, false);
    assert.equal(reply.heardLeft, 140);
    // Listening costs nothing in answers.
    assert.equal(reply.creditsLeft, 25);
  });

  it('stops new sessions once the day\'s listening is used, until midnight', async () => {
    await addCustomer('owner@x.com');
    const session = await signIn('owner@x.com');
    const auth = await api.authenticate(bearer(session));
    await api.authorizeSession(auth);
    await heard(session, 'batch-00000001', 100);
    await api.authorizeSession(auth);
    const last = await heard(session, 'batch-00000002', 60);
    assert.equal(last.heardLeft, 0);
    await fails(api.authorizeSession(auth), 402, 'out_of_listening');
    // Midnight in India: a new day.
    advance(DAY);
    const fresh = await api.authenticate(bearer(await api.refresh({ refreshToken: session.refreshToken, installId: installA })));
    await api.authorizeSession(fresh);
  });

  it('is not applied to someone on unlimited, though the count is still kept', async () => {
    await api.admin.grant('payer@x.com', 'unlimited');
    const session = await signIn('payer@x.com');
    const reply = await heard(session, 'batch-00000001', 180);
    assert.equal(reply.heardLimit, null);
    assert.equal(reply.heardLeft, null);
    assert.equal(reply.heardToday, 180);
    await api.authorizeSession(await api.authenticate(bearer(session)));
  });

  it('refuses a malformed report and caps an absurd one', async () => {
    await addCustomer('owner@x.com');
    const session = await signIn('owner@x.com');
    await fails(heard(session, 'x', 5), 400, 'bad_request');
    await fails(heard(session, 'batch-00000001', 0), 400, 'bad_request');
    await fails(heard(session, 'batch-00000001', 'lots'), 400, 'bad_request');
    const reply = await heard(session, 'batch-00000002', 5_000_000);
    assert.equal(reply.heardToday, 200);
  });
});

describe('the App Review sign-in', () => {
  const review = 'review@ordinary.test';
  const withReview = (extra = {}) => createAccounts({
    store, ordinary, mailer, secrets: { jwt: 'jwt-secret', otp: 'otp-secret' }, clock,
    config: { reviewEmail: 'Review@Ordinary.test', reviewCode: '482913', ...extra },
  });
  const enter = (svc, code, installId = installA) =>
    svc.verify({ email: review, code, installId, deviceName: 'iPad', platform: 'ios', tz: 'America/Los_Angeles' });

  it('signs in with the fixed code, sends no mail, and is treated as an owner', async () => {
    const svc = withReview();
    assert.deepEqual(await svc.start({ email: review, ip: '9.9.9.9' }), { ok: true });
    assert.equal(sent.length, 0);
    const session = await enter(svc, '482913');
    assert.ok(session.accessToken);
    const auth = await svc.authenticate(`Bearer ${session.accessToken}`);
    assert.equal((await svc.entitlementFor(review)).tier, 'unlimited');
    await svc.me(auth);
    await svc.authorizeSession(auth);
  });

  it('refuses a wrong code, and stops counting guesses after a few dozen', async () => {
    const svc = withReview({ reviewTriesPerHour: 3 });
    await fails(enter(svc, '000000'), 401, 'bad_code');
    await fails(enter(svc, ''), 401, 'bad_code');
    await fails(enter(svc, '111111'), 401, 'bad_code');
    // Even the right code is refused once the hour's tries are spent.
    await fails(enter(svc, '482913'), 429, 'code_locked');
    advance(HOUR + MIN);
    assert.ok((await enter(svc, '482913')).accessToken);
  });

  it('moves to a third device without asking which one to sign out', async () => {
    const svc = withReview();
    await enter(svc, '482913', installA);
    advance(MIN);
    await enter(svc, '482913', installB);
    advance(MIN);
    const third = await enter(svc, '482913', installC);
    assert.ok(third.accessToken);
    const live = await ordinary.collection('devices').find({ revokedAt: null }).toArray();
    assert.deepEqual(live.map((d) => d.installId).sort(), [installB, installC]);
  });

  it('does not exist unless configured, and can be shut by revoking it', async () => {
    // Not configured: the address is a stranger like any other.
    await api.start({ email: review, ip: '9.9.9.9' });
    await fails(api.verify({ email: review, code: '482913', installId: installA, tz: 'UTC' }), 401);
    // A code too short to be safe is ignored as well.
    const weak = withReview({ reviewCode: '123' });
    await fails(enter(weak, '123'), 401);
    // Configured, then revoked.
    const svc = withReview();
    await ordinary.collection('revoked').insertOne({ email: review, orderId: null, at: clock() });
    await fails(enter(svc, '482913'), 403, 'revoked');
  });

  it('leaves everyone else on the emailed code', async () => {
    const svc = withReview();
    await addCustomer('owner@x.com');
    await svc.start({ email: 'owner@x.com', ip: '1.1.1.1' });
    assert.equal(sent.length, 1);
    await fails(svc.verify({ email: 'owner@x.com', code: '482913', installId: installA, tz: 'UTC' }), 401, 'bad_code');
  });
});

describe('tokens', () => {
  it('rejects a tampered, expired or malformed token', () => {
    const token = signJwt({ sub: 'a' }, 's', 60, 1_000_000);
    assert.equal(verifyJwt(token, 's', 1_000_000).ok, true);
    assert.equal(verifyJwt(token, 'other', 1_000_000).code, 'token_invalid');
    assert.equal(verifyJwt(token, 's', 1_000_000 + 61_000).code, 'token_expired');
    assert.equal(verifyJwt(`${token}x`, 's', 1_000_000).code, 'token_invalid');
    assert.equal(verifyJwt('nope', 's').code, 'token_invalid');
    // Forged body under the original signature.
    const [h, , sig] = token.split('.');
    const forged = `${h}.${Buffer.from(JSON.stringify({ sub: 'b', exp: 9e9 })).toString('base64url')}.${sig}`;
    assert.equal(verifyJwt(forged, 's', 1_000_000).code, 'token_invalid');
  });
});

describe('who is an owner', () => {
  it('an active order counts, paid online or cash on delivery, at once', async () => {
    await addCustomer('online@x.com', { paymentMethod: 'online' });
    await addCustomer('cod@x.com', { paymentMethod: 'cod' });
    assert.equal((await api.entitlementFor('online@x.com')).tier, 'free');
    assert.equal((await api.entitlementFor('cod@x.com')).tier, 'free');
  });

  it('an abandoned checkout, or no order, does not', async () => {
    await addCustomer('abandoned@x.com', { status: 'created' });
    await addCustomer('nobody@x.com', { status: null });
    assert.deepEqual([(await api.entitlementFor('abandoned@x.com')).tier, (await api.entitlementFor('nobody@x.com')).tier, (await api.entitlementFor('stranger@x.com')).tier], ['none', 'none', 'none']);
  });

  it('matches the email whatever its capitals, and across duplicate records', async () => {
    await addCustomer('Mixed.Case@X.com', { status: 'created' });
    await addCustomer('mixed.case@x.com');
    assert.equal((await api.entitlementFor('  MIXED.case@x.COM ')).tier, 'free');
  });

  it('a manual revoke removes access, by person or by order; undoing restores it', async () => {
    const a = await addCustomer('a@x.com', { paymentMethod: 'cod' });
    await addCustomer('b@x.com', { paymentMethod: 'cod' });
    await api.admin.revoke(String(a.orderId), 'parcel refused');
    await api.admin.revoke('b@x.com', 'returned');
    assert.equal((await api.entitlementFor('a@x.com')).tier, 'none');
    assert.equal((await api.entitlementFor('b@x.com')).reason, 'revoked');
    await api.admin.unrevoke(String(a.orderId));
    await api.admin.unrevoke('b@x.com');
    assert.equal((await api.entitlementFor('a@x.com')).tier, 'free');
    assert.equal((await api.entitlementFor('b@x.com')).tier, 'free');
  });

  it('a grant lets a non-buyer in, and "unlimited" outranks the free allowance until it ends', async () => {
    await api.admin.grant('tester@x.com', 'free');
    assert.equal((await api.entitlementFor('tester@x.com')).tier, 'free');
    await addCustomer('payer@x.com');
    await api.admin.grant('Payer@x.com', 'unlimited', { until: new Date(now + 30 * DAY) });
    assert.equal((await api.entitlementFor('payer@x.com')).tier, 'unlimited');
    advance(31 * DAY);
    assert.equal((await api.entitlementFor('payer@x.com')).tier, 'free'); // back to the owner allowance
    await api.admin.ungrant('tester@x.com');
    assert.equal((await api.entitlementFor('tester@x.com')).tier, 'none');
  });
});

describe('sign-in', () => {
  beforeEach(async () => { await addCustomer('owner@x.com'); });

  it('an owner gets a code and signs in with it, once', async () => {
    const session = await signIn('owner@x.com');
    assert.match(lastCode('owner@x.com'), /^\d{6}$/);
    assert.equal(session.account.email, 'owner@x.com');
    assert.equal(session.entitlement.tier, 'free');
    assert.equal(session.credits.creditsLeft, 25);
    assert.equal(session.devices.length, 1);
    assert.equal(session.devices[0].current, true);
    // The same code cannot be used again.
    await fails(api.verify({ email: 'owner@x.com', code: lastCode('owner@x.com'), installId: installA }), 401, 'code_expired');
  });

  it('answers the same for a customer and a stranger, and never sends a stranger a code', async () => {
    const a = await api.start({ email: 'owner@x.com', ip: '2.2.2.2' });
    const b = await api.start({ email: 'stranger@x.com', ip: '2.2.2.2' });
    assert.deepEqual(a, b);
    assert.deepEqual(sent.find((m) => m.to === 'stranger@x.com'), { to: 'stranger@x.com', noPurchase: true });
    // And only one such email a day, however often it is asked.
    advance(2 * MIN); await api.start({ email: 'stranger@x.com', ip: '2.2.2.3' });
    assert.equal(sent.filter((m) => m.to === 'stranger@x.com').length, 1);
    await fails(api.verify({ email: 'stranger@x.com', code: '000000', installId: installA }), 401, 'code_expired');
  });

  it('a wrong code counts down, then locks; a right code after the lock is refused', async () => {
    await api.start({ email: 'owner@x.com', ip: '3.3.3.3' });
    const real = lastCode('owner@x.com');
    const wrong = real === '111111' ? '222222' : '111111';
    for (let left = 4; left >= 0; left--) {
      await assert.rejects(api.verify({ email: 'owner@x.com', code: wrong, installId: installA }), (e) => e.status === 401 && e.body.attemptsLeft === left);
    }
    await fails(api.verify({ email: 'owner@x.com', code: real, installId: installA }), 429, 'code_locked');
  });

  it('a code expires after ten minutes', async () => {
    await api.start({ email: 'owner@x.com', ip: '4.4.4.4' });
    advance(11 * MIN);
    await fails(api.verify({ email: 'owner@x.com', code: lastCode('owner@x.com'), installId: installA }), 401, 'code_expired');
  });

  it('asking again within a minute keeps the first code; too many requests are slowed', async () => {
    await api.start({ email: 'owner@x.com', ip: '5.5.5.5' });
    const first = lastCode('owner@x.com');
    await api.start({ email: 'owner@x.com', ip: '5.5.5.5' });
    assert.equal(sent.filter((m) => m.code).length, 1);
    assert.equal(lastCode('owner@x.com'), first);
    for (let i = 0; i < 4; i++) { advance(61_000); await api.start({ email: 'owner@x.com', ip: '5.5.5.5' }); }
    advance(61_000);
    await fails(api.start({ email: 'owner@x.com', ip: '5.5.5.5' }), 429, 'slow_down');
  });

  it('one address cannot request codes for many emails', async () => {
    for (let i = 0; i < 20; i++) await api.start({ email: `p${i}@x.com`, ip: '6.6.6.6' });
    await fails(api.start({ email: 'owner@x.com', ip: '6.6.6.6' }), 429, 'slow_down');
  });

  it('rejects something that is not an email', async () => {
    await fails(api.start({ email: 'not-an-email', ip: '7.7.7.7' }), 400, 'bad_email');
  });

  it('someone whose access was revoked after buying cannot finish signing in', async () => {
    await api.start({ email: 'owner@x.com', ip: '8.8.8.8' });
    await api.admin.revoke('owner@x.com');
    await fails(api.verify({ email: 'owner@x.com', code: lastCode('owner@x.com'), installId: installA }), 403, 'revoked');
  });
});

describe('staying signed in', () => {
  beforeEach(async () => { await addCustomer('owner@x.com'); });

  it('an access token works, expires after 15 minutes, and a refresh gives a new pair', async () => {
    const session = await signIn('owner@x.com');
    assert.equal((await api.me(await api.authenticate(bearer(session)))).account.email, 'owner@x.com');
    advance(16 * MIN);
    await fails(api.authenticate(bearer(session)), 401, 'token_expired');
    const next = await api.refresh({ refreshToken: session.refreshToken, installId: installA });
    assert.notEqual(next.refreshToken, session.refreshToken);
    assert.ok(await api.authenticate(bearer(next)));
  });

  it('a refresh token works once; an old one used later signs that phone out', async () => {
    const session = await signIn('owner@x.com');
    const second = await api.refresh({ refreshToken: session.refreshToken, installId: installA });
    // A retry straight away (the reply was lost) is tolerated…
    const retry = await api.refresh({ refreshToken: session.refreshToken, installId: installA });
    assert.ok(retry.refreshToken);
    // The pair from the lost reply was replaced by the retry's and is dead.
    await fails(api.refresh({ refreshToken: second.refreshToken, installId: installA }), 401, 'signed_out');
    // The newest one still works…
    const third = await api.refresh({ refreshToken: retry.refreshToken, installId: installA });
    // …but an already-used token turning up minutes later means it was copied:
    // that phone is signed out, its newest token included.
    advance(5 * MIN);
    await fails(api.refresh({ refreshToken: retry.refreshToken, installId: installA }), 401, 'signed_out');
    await fails(api.refresh({ refreshToken: third.refreshToken, installId: installA }), 401, 'signed_out');
  });

  it('a refresh token is tied to its phone and lapses after 90 days unused', async () => {
    const session = await signIn('owner@x.com');
    await fails(api.refresh({ refreshToken: session.refreshToken, installId: installB }), 401, 'signed_out');
    advance(91 * DAY);
    await fails(api.refresh({ refreshToken: session.refreshToken, installId: installA }), 401, 'signed_out');
    await fails(api.refresh({ refreshToken: 'made-up', installId: installA }), 401, 'signed_out');
  });

  it('signing out ends that phone at once, access token included', async () => {
    const session = await signIn('owner@x.com');
    await api.signOut(await api.authenticate(bearer(session)));
    await fails(api.authenticate(bearer(session)), 401, 'signed_out');
    await fails(api.refresh({ refreshToken: session.refreshToken, installId: installA }), 401, 'signed_out');
  });

  it('losing ownership is noticed at the next refresh and blocks new sessions', async () => {
    const session = await signIn('owner@x.com');
    await api.admin.revoke('owner@x.com', 'returned');
    await fails(api.authorizeSession(await api.authenticate(bearer(session))), 403, 'revoked');
    const next = await api.refresh({ refreshToken: session.refreshToken, installId: installA });
    assert.equal(next.entitlement.tier, 'none');
  });

  it('deleting the account erases Ordinary\'s record and leaves the store alone', async () => {
    const session = await signIn('owner@x.com');
    const auth = await api.authenticate(bearer(session));
    await api.recordAnswer(auth, 'exchange-0001');
    await api.deleteAccount(auth);
    for (const name of ['accounts', 'devices', 'usage_days', 'usage_events']) {
      assert.equal(await ordinary.collection(name).countDocuments({}), 0, name);
    }
    assert.equal(await store.collection('users').countDocuments({}), 1);
    assert.equal(await store.collection('orders').countDocuments({}), 1);
    await fails(api.authenticate(bearer(session)), 401, 'signed_out');
  });
});

describe('two phones', () => {
  beforeEach(async () => { await addCustomer('owner@x.com'); });

  it('a second phone joins; a third must choose one to sign out', async () => {
    const a = await signIn('owner@x.com', installA);
    advance(2 * MIN);
    const b = await signIn('owner@x.com', installB);
    assert.equal(b.devices.length, 2);

    advance(2 * MIN);
    await api.start({ email: 'owner@x.com', ip: '1.1.1.1' });
    let refusal;
    await assert.rejects(api.verify({ email: 'owner@x.com', code: lastCode('owner@x.com'), installId: installC }), (e) => { refusal = e; return e.status === 409; });
    assert.equal(refusal.body.code, 'device_limit');
    assert.equal(refusal.body.devices.length, 2);

    // No second code needed: the ticket carries the proof for ten minutes.
    const victim = refusal.body.devices[0].id;
    const c = await api.verify({ ticket: refusal.body.ticket, installId: installC, replaceDeviceId: victim, deviceName: 'Third', platform: 'android' });
    assert.equal(c.devices.length, 2);
    await fails(api.authenticate(bearer(a)), 401, 'signed_out');
    assert.ok(await api.authenticate(bearer(b)));
  });

  it('the ticket only works for the phone it was given to, and not for a phone that is not on the list', async () => {
    await signIn('owner@x.com', installA);
    advance(2 * MIN); await signIn('owner@x.com', installB);
    advance(2 * MIN); await api.start({ email: 'owner@x.com', ip: '1.1.1.1' });
    let refusal;
    await assert.rejects(api.verify({ email: 'owner@x.com', code: lastCode('owner@x.com'), installId: installC }), (e) => { refusal = e; return true; });
    await fails(api.verify({ ticket: refusal.body.ticket, installId: 'install-dddddddddddddddd', replaceDeviceId: refusal.body.devices[0].id }), 401, 'bad_code');
    await fails(api.verify({ ticket: refusal.body.ticket, installId: installC, replaceDeviceId: String(new ObjectId()) }), 409, 'device_limit');
    advance(11 * MIN);
    await fails(api.verify({ ticket: refusal.body.ticket, installId: installC, replaceDeviceId: refusal.body.devices[0].id }), 401, 'bad_code');
  });

  it('the same phone signing in again does not use up a slot; removing one frees it', async () => {
    const a = await signIn('owner@x.com', installA);
    advance(2 * MIN); await signIn('owner@x.com', installA);
    advance(2 * MIN); const b = await signIn('owner@x.com', installB);
    assert.equal(b.devices.length, 2);
    const auth = await api.authenticate(bearer(b));
    const other = b.devices.find((d) => !d.current).id;
    await api.removeDevice(auth, other);
    assert.equal((await api.me(auth)).devices.length, 1);
    await fails(api.removeDevice(auth, String(new ObjectId())), 404);
    advance(2 * MIN); const c = await signIn('owner@x.com', installC);
    assert.equal(c.devices.length, 2);
    assert.ok(a);
  });
});

describe('daily credits', () => {
  let auth;
  beforeEach(async () => {
    await addCustomer('owner@x.com');
    auth = await api.authenticate(bearer(await signIn('owner@x.com')));
  });

  it('25 answers a day, then sessions are refused until local midnight', async () => {
    assert.equal((await api.authorizeSession(auth)).creditsLeft, 25);
    for (let i = 0; i < 25; i++) await api.recordAnswer(auth, `exchange-${String(i).padStart(4, '0')}`);
    let refusal;
    await assert.rejects(api.authorizeSession(auth), (e) => { refusal = e; return e.status === 402; });
    assert.equal(refusal.body.code, 'out_of_credits');
    assert.equal(refusal.body.creditsLeft, 0);
    assert.equal(refusal.body.resetsAt, '2026-10-05T18:30:00.000Z'); // midnight in India

    now = Date.parse(refusal.body.resetsAt) + 1000;
    assert.equal((await api.authorizeSession(auth)).creditsLeft, 25);
  });

  it('reporting the same answer twice charges once', async () => {
    const first = await api.recordAnswer(auth, 'exchange-same');
    const again = await api.recordAnswer(auth, 'exchange-same');
    assert.deepEqual([first.counted, first.creditsLeft, again.counted, again.creditsLeft], [true, 24, false, 24]);
  });

  it('forty answers reported at once from two phones never go past 25', async () => {
    const second = await api.authenticate(bearer(await (advance(2 * MIN), signIn('owner@x.com', installB))));
    const results = await Promise.all(Array.from({ length: 40 }, (_, i) => api.recordAnswer(i % 2 ? auth : second, `burst-${String(i).padStart(4, '0')}`)));
    assert.equal(Math.min(...results.map((r) => r.creditsLeft)), 0);
    const day = await ordinary.collection('usage_days').findOne({});
    assert.equal(day.answers, 25);
    assert.equal(await ordinary.collection('usage_days').countDocuments({}), 1);
  });

  it('the day turns over at the account\'s own midnight, not UTC', async () => {
    assert.equal(dayKey('Asia/Kolkata', new Date('2026-10-05T18:29:59Z')), '2026-10-05');
    assert.equal(dayKey('Asia/Kolkata', new Date('2026-10-05T18:30:00Z')), '2026-10-06');
    assert.equal(nextMidnight('America/New_York', new Date('2026-10-05T12:00:00Z')).toISOString(), '2026-10-06T04:00:00.000Z');
    assert.equal(nextMidnight('UTC', new Date('2026-10-05T23:59:59Z')).toISOString(), '2026-10-06T00:00:00.000Z');
  });

  it('unlimited has no daily limit, and falls back to 25 when it ends', async () => {
    await api.admin.grant('owner@x.com', 'unlimited', { until: new Date(now + 2 * DAY) });
    const fresh = await api.authenticate(bearer(await (advance(2 * MIN), signIn('owner@x.com'))));
    for (let i = 0; i < 40; i++) await api.recordAnswer(fresh, `unl-${String(i).padStart(4, '0')}`);
    const open = await api.authorizeSession(fresh);
    assert.deepEqual([open.tier, open.dailyLimit, open.creditsLeft, open.usedToday], ['unlimited', null, null, 40]);

    advance(3 * DAY);
    const later = await api.authorizeSession(await api.authenticate(bearer(await signIn('owner@x.com'))));
    assert.deepEqual([later.tier, later.creditsLeft], ['free', 25]);
  });

  it('a runaway or modified app is stopped by the session ceiling even with credits left', async () => {
    const tight = createAccounts({ store, ordinary, mailer, secrets: { jwt: 'jwt-secret', otp: 'otp-secret' }, clock, config: { mintsPerDayFree: 3 } });
    for (let i = 0; i < 3; i++) await tight.authorizeSession(auth);
    await fails(tight.authorizeSession(auth), 429, 'too_many_sessions');
  });

  it('refuses a malformed answer id and a blocked account', async () => {
    await fails(api.recordAnswer(auth, 'x'), 400, 'bad_request');
    await ordinary.collection('accounts').updateOne({}, { $set: { status: 'blocked' } });
    const blocked = { ...auth, account: await ordinary.collection('accounts').findOne({}) };
    await fails(api.authorizeSession(blocked), 403, 'blocked');
  });
});

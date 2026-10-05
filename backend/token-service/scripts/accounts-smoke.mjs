/**
 * End-to-end check of accounts over HTTP, against a running token service.
 * Prints no tokens or secrets.
 *
 *   node --env-file=.env scripts/accounts-smoke.mjs start  <email>
 *   node --env-file=.env scripts/accounts-smoke.mjs finish <email> <code>
 *
 * BASE overrides the server (default: the deployed one).
 */
const BASE = process.env.BASE ?? 'https://oyurx6vlprfvlq44qvj4zjwop40rhtwk.lambda-url.ap-south-1.on.aws';
const key = process.env.ORDI_CLIENT_SECRET ?? '';
const [step, email, code] = process.argv.slice(2);
const installId = 'smoke-test-install-0001';

async function call(method, path, body, token) {
  const response = await fetch(BASE + path, {
    method,
    headers: { 'content-type': 'application/json', 'x-ordi-key': key, ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  let json = null;
  try { json = JSON.parse(text); } catch { /* not JSON */ }
  return { status: response.status, json, text };
}
const show = (label, r, pick) => console.log(label.padEnd(34), r.status, pick ? JSON.stringify(pick(r.json ?? {})) : '');

if (step === 'start') {
  show('POST /auth/start', await call('POST', '/auth/start', { email }), (j) => j);
  show('POST /auth/start (stranger)', await call('POST', '/auth/start', { email: `nobody-${Date.now()}@example.invalid` }), (j) => j);
  process.exit(0);
}

const wrong = await call('POST', '/auth/verify', { email, code: code === '000000' ? '111111' : '000000', installId });
show('verify with a wrong code', wrong, (j) => ({ code: j.code, attemptsLeft: j.attemptsLeft }));

const signedIn = await call('POST', '/auth/verify', { email, code, installId, deviceName: 'Smoke test', platform: 'ios', tz: 'Asia/Kolkata' });
show('verify with the right code', signedIn, (j) => ({ entitlement: j.entitlement, credits: j.credits, devices: j.devices?.length, hasTokens: Boolean(j.accessToken && j.refreshToken) }));
if (signedIn.status !== 200) process.exit(1);
let { accessToken, refreshToken } = signedIn.json;

show('verify again with the same code', await call('POST', '/auth/verify', { email, code, installId }), (j) => ({ code: j.code }));
show('GET /me', await call('GET', '/me', null, accessToken), (j) => ({ tier: j.entitlement?.tier, left: j.credits?.creditsLeft }));
show('GET /me without sign-in', await call('GET', '/me'), (j) => ({ code: j.code }));
show('GET /me with a forged token', await call('GET', '/me', null, `${accessToken}x`), (j) => ({ code: j.code }));

const session = await call('POST', '/session', { deviceId: installId, tools: true, toolsV2: true, toolsV3: true, toolsV4: true, now: new Date().toISOString() }, accessToken);
show('POST /session (signed in)', session, (j) => ({ gotGeminiToken: Boolean(j.token), model: j.model, credits: j.credits }));

const legacy = await call('POST', '/session', { deviceId: 'legacy-build-device', tools: true, now: new Date().toISOString() });
show('POST /session (old build, no sign-in)', legacy, (j) => ({ gotGeminiToken: Boolean(j.token), error: j.error }));

const id = `smoke-${Date.now()}`;
show('POST /usage/answer', await call('POST', '/usage/answer', { exchangeId: id }, accessToken), (j) => ({ counted: j.counted, left: j.creditsLeft }));
show('POST /usage/answer (same again)', await call('POST', '/usage/answer', { exchangeId: id }, accessToken), (j) => ({ counted: j.counted, left: j.creditsLeft }));

const refreshed = await call('POST', '/auth/refresh', { refreshToken, installId });
show('POST /auth/refresh', refreshed, (j) => ({ rotated: Boolean(j.refreshToken) && j.refreshToken !== refreshToken }));
accessToken = refreshed.json?.accessToken ?? accessToken;

show('POST /auth/signout', await call('POST', '/auth/signout', {}, accessToken), (j) => j);
show('GET /me after sign-out', await call('GET', '/me', null, accessToken), (j) => ({ code: j.code }));
show('refresh after sign-out', await call('POST', '/auth/refresh', { refreshToken: refreshed.json?.refreshToken, installId }), (j) => ({ code: j.code }));

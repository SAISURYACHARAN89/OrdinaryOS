/**
 * HTTP surface for accounts: sign-in, the signed-in person's own record, and
 * usage reporting. Thin on purpose — every decision is in `accounts.js`.
 */
import { createAccounts, ensureIndexes, HttpError } from './accounts.js';
import { databases } from './db.js';
import { createMailer } from './mail.js';

let service = null;

/** The account service, or null when no database is configured. */
export async function accountService() {
  if (service) return service;
  const dbs = await databases();
  if (!dbs) return null;
  await ensureIndexes(dbs.ordinary);
  service = createAccounts({
    store: dbs.store,
    ordinary: dbs.ordinary,
    mailer: createMailer(),
    secrets: { jwt: process.env.JWT_SECRET, otp: process.env.OTP_HMAC_SECRET },
    config: {
      dailyCredits: Number(process.env.DAILY_CREDITS ?? 25),
      // The App Review sign-in; see accounts.js. Off unless both are set.
      reviewEmail: process.env.REVIEW_EMAIL ?? '',
      reviewCode: process.env.REVIEW_CODE ?? '',
    },
  });
  return service;
}

const ROUTES = new Set([
  'POST /auth/start', 'POST /auth/verify', 'POST /auth/refresh', 'POST /auth/signout',
  'GET /me', 'POST /me/devices/remove', 'POST /me/delete', 'POST /usage/answer',
]);

export const isAccountRoute = (req) => ROUTES.has(`${req.method} ${req.url}`);

/** Behind a proxy (the Lambda URL) the caller's address is the first hop. */
function clientIp(req) {
  const forwarded = String(req.headers['x-forwarded-for'] ?? '').split(',')[0].trim();
  return forwarded || req.socket?.remoteAddress || '';
}

/** Sends an `HttpError` as its own status and body; anything else as a 500. */
export function sendError(res, send, error, where) {
  if (error instanceof HttpError) return send(res, error.status, error.body);
  console.error(`[accounts] ${where} failed:`, error?.message ?? error);
  return send(res, 500, { code: 'server_error', error: 'Something went wrong. Try again.' });
}

export async function handleAccountRoute(req, res, { readJson, send, getService = accountService }) {
  const route = `${req.method} ${req.url}`;
  try {
    const accounts = await getService();
    if (!accounts) return send(res, 503, { code: 'accounts_unavailable', error: 'Accounts are not set up on this server.' });

    const body = req.method === 'POST' ? await readJson(req).catch(() => { throw new HttpError(400, { code: 'bad_request', error: 'Body was not valid JSON.' }); }) : {};

    switch (route) {
      case 'POST /auth/start':
        return send(res, 200, await accounts.start({ email: body.email, ip: clientIp(req) }));
      case 'POST /auth/verify':
        return send(res, 200, await accounts.verify(body));
      case 'POST /auth/refresh':
        return send(res, 200, await accounts.refresh(body));
    }

    const auth = await accounts.authenticate(req.headers.authorization);
    switch (route) {
      case 'POST /auth/signout':
        return send(res, 200, await accounts.signOut(auth));
      case 'GET /me':
        return send(res, 200, await accounts.me(auth));
      case 'POST /me/devices/remove':
        return send(res, 200, await accounts.removeDevice(auth, body.deviceId));
      case 'POST /me/delete':
        return send(res, 200, await accounts.deleteAccount(auth));
      case 'POST /usage/answer':
        return send(res, 200, await accounts.recordAnswer(auth, body.exchangeId));
    }
    return send(res, 404, { error: 'Not found.' });
  } catch (error) {
    return sendError(res, send, error, route);
  }
}

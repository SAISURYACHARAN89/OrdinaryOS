# Ordinary accounts & credits (owners only)

## Context

Ordinary is open to anyone who has the app and the build's client key: the
1,350 credits are hardcoded (`home_screen.dart:206`, `:146`), the device id is
random per launch (`session.dart:75-82`), and the token service stores nothing
(in-memory, off-by-default `claimSession`, `server.js:488-517`). Every Gemini
turn costs us money, so access must be limited to people who **bought our
glasses/products**, recorded in the Tricher store's MongoDB (cluster `tricher`).

Decisions (from the user):
- Only owners can use the app; non-owners get nothing (a clear "for owners"
  screen with a store link).
- **Free tier (owners): 25 credits/day, 1 credit = 1 answer from Ordinary.**
  Overheard speech Ordinary ignores, reminders it speaks, and voice samples are
  free.
- **Paid tier: unlimited (with fair-use caps)**, bought **on the website**; it
  shows up in the app after payment. No in-app payments.
- Sign-in: **email code** (the purchase email). **2 phones** per account,
  self-service sign-out of the other one.
- COD orders unlock **only once delivered**; prepaid unlocks at once.
- **Do not change the store backend.** Ordinary only *reads* store data.

Findings in the store (`~/Documents/TricherNew/halo-learn/backedn`):
- `User{email unique, name, mobile}`.
- `Order{user, plan, paymentMethod, status: created→active, shiprocketAwb,
  delhiveryWaybill, shipmentStatus}`.
- `Plan{name, price, durationInDays}`.
- `Subscription{user, plan, order, expiryDate, isActive}`.
- An order becomes `active` on Razorpay verify **or** straight away on COD
  confirmation, and `shipmentStatus` never reaches "delivered" (no webhook).
- Its OTP/licence endpoints have holes: an in-memory OTP store, no per-email
  attempt limit, email enumeration, and unauthenticated device reset. Ordinary
  runs its own sign-in and does not reuse them.

## Decisions added 2026-10-03 (these override the sections below where they differ)

- **All three store plans (`basic`, `pro`, `tricher`) are glasses.** Any order
  with status `active` makes its buyer an owner; the app does not read or label
  plans at all. `HARDWARE_PLANS` is not needed.
- **Access starts immediately after the order, for online and COD alike**
  (decided 2026-10-03, replacing both "once delivered" and "15 days"). The
  store already sets an order to `active` on Razorpay verify and on COD
  confirmation, so the rule is simply: an `active` order = owner. No courier
  check, no `deliveredAt`, no Shiprocket/Delhivery credentials, no
  `deliveries` collection.
- **The user marks COD orders by hand** when one is refused or returned; that
  mark removes access. The admin script must make this one command (by email
  or order id), and the entitlement check must honour it within minutes.
- **Leave the store's `plans` collection alone.** The app ignores it, but the
  store's checkout reads it to create every order (`routes/payments.js:233`)
  and re-creates it at startup (`server.js:102`), so deleting it would break
  buying and it would come back anyway.
- Live data (database `test`): 523 users, 555 orders (181 `active`), 300 COD /
  255 online, 182 subscriptions. `orders` has no index besides `_id`; add
  `{user: 1, status: 1}`.
- Open: how the paid unlimited tier is recorded, since plans are not used.

## Architecture

- **Ordinary account service inside the token service** (the same Lambda that
  mints Gemini tokens), so the token check, entitlement and credits live in one
  place.
- **Data:**
  - A new **`ordinary` database** in the same Atlas cluster for Ordinary's own
    data.
  - The store's `users`, `orders`, `plans` and `subscriptions` are read through
    a **least-privilege DB user**: read on the store DB, readWrite on
    `ordinary`.
  - Dependency: `mongodb` driver (Apache-2.0). The client is global, so it is
    reused across Lambda invocations; pool size 5.
- **Phone:** tokens and a persistent install id live in secure storage
  (Keychain / Android Keystore) via `flutter_secure_storage` (BSD).

### Entitlement (computed server-side, cached 10 min per account)
1. Blocked account → **none**.
2. Admin grant for the email (team, testers, App Review, influencers) → its tier.
3. An active store Subscription on a plan in `PAID_PLANS` with
   `expiryDate > now` → **paid** (with `paidUntil`).
4. An Order with status `active` on a plan in `HARDWARE_PLANS`:
   - prepaid → **free-owner**;
   - COD → **free-owner** only once the courier says delivered. Checked via the
     Shiprocket AWB / Delhivery waybill tracking APIs and cached in
     `ordinary.deliveries`. Re-checked at most every 30 min while pending;
     final once delivered; RTO or cancelled → not an owner.
5. Otherwise → **none**, with a reason: `no_purchase` | `awaiting_delivery`.

`HARDWARE_PLANS` / `PAID_PLANS` are env config (default `tricher`
hardware). A paid plan is added by inserting a `Plan` document (for example
`ordinary-unlimited`, 30 days) that the store's existing checkout already
sells, so no store code changes.

### Collections (`ordinary` DB)
- `accounts`: `{email (lower, unique), storeUserId, tz, status, createdAt,
  lastSignInAt, entitlementCache}`
- `devices`: `{accountId, installId, name, platform, refreshHash, family,
  createdAt, lastSeenAt, revokedAt}`. At most 2 active.
- `otp`: `{emailHash, codeHmac, attempts, expiresAt (TTL), sentCount, ip}`
- `usage_days`: `{accountId, day (account-local date), answers, mints}`,
  unique on (accountId, day)
- `usage_events`: `{accountId, installId, exchangeId (unique), day, at}` for
  idempotency and audit. TTL 90 days.
- `grants`: `{email, tier, until, note}`
- `deliveries`: `{orderId, status, checkedAt}`
- `ratelimits`: `{key, windowStart, count}` (TTL)

### Endpoints (token service; bodies capped, JSON only)
- `POST /auth/start {email}`
  - Always `200 {ok}`, so emails can't be enumerated.
  - Owner or grant → emails a 6-digit code.
  - Unknown email → emails "no Ordinary purchase found with this address", so
    a mistyped email isn't a silent dead end.
  - Limits: 60 s resend cooldown, 5 sends/hour/email, 20/hour/IP.
- `POST /auth/verify {email, code, installId, deviceName, platform, tz,
  replaceDeviceId?}`
  - The code is HMAC-hashed and compared in constant time. 5 wrong tries locks
    it; it expires after 10 min; it can be used once.
  - Returns `{accessToken, refreshToken, account, entitlement}`.
  - `409 device_limit {devices}` when a third phone signs in; the app lets the
    user pick one to sign out and retries with `replaceDeviceId`.
- `POST /auth/refresh {refreshToken, installId}`
  - Rotates the refresh token every time.
  - Reusing an old one revokes that device (theft detection).
  - Refresh tokens last 90 days, sliding.
- `POST /auth/signout`; `GET /me`; `DELETE /me/devices/:id`
- `POST /me/delete` erases the Ordinary account data, never store data. Apple
  requires in-app deletion for accounts created in the app.
- **Access token:** JWT (HS256, key id for rotation), 15 min. Claims:
  `sub, did, tier, exp, jti`. Verified with no DB call.
- `POST /session` (now needs `Authorization: Bearer`):
  - checks entitlement;
  - free with 0 credits left → `402 {code:'out_of_credits', resetsAt}`;
  - none → `403 {code: no_purchase | awaiting_delivery}`;
  - returns `creditsLeft, dailyLimit, resetsAt, tier`.
- `POST /usage/answer {exchangeId}`: an idempotent debit via a conditional
  atomic `$inc` (`answers < limit`), returning `creditsLeft`. Duplicate reports
  are no-ops, and two phones can't overspend.
- `/session-insights`: needs auth; not charged; counts toward fair use.
  `/diag`: unchanged.

### Metering and its limits (stated honestly)
- **The server never sees Gemini traffic**, so answers are reported by the app.
  - Source: the engine's existing exchange-complete event
    (`exchangeQuestion`/`exchangeAnswer`, which only fires when the user said
    something).
  - Each report carries a UUID and waits in a persisted retry queue while
    offline.
- **Server-side backstops** that a modified app cannot bypass:
  - no token at 0 credits;
  - tokens expire (≤10 min) and must be re-minted;
  - a per-account daily **mint ceiling** (free ≈ 60, paid ≈ 400);
  - an alert when many mints come with no reported answers;
  - a Google project budget alert.
- **Daily reset** at local midnight in the account's timezone, taken at sign-in
  (IANA name from an allow-list, updated at most once a day).
- **Running out mid-conversation:** the current answer finishes. The app then
  closes the session and shows "Daily limit reached · resets 12:00 AM", with a
  notification. Scheduled reminders still arrive as notifications.

### Paid via website: store-policy guard
- Buying happens on the website. On return to the app it refreshes `/me` (on
  resume, plus a "Refresh" button), so the tier updates within seconds.
- An in-app "Upgrade" link to the website breaks Apple 3.1.1 outside the US
  storefront, and Google Play rules without Play's alternative-billing
  enrolment. Guard:
  - The server returns `upgradeUrl` only for platform/storefront combinations
    where it is allowed.
  - Elsewhere the app shows plan status (Unlimited until X / 25 per day) with
    no purchase link.
  - This is the same behaviour for everyone, including App Review; nothing is
    hidden from reviewers.

## App changes

- **Account (new):** `lib/models/account.dart`. It holds:
  - a persistent install id;
  - tokens in secure storage;
  - single-flight refresh ahead of expiry;
  - an entitlement `ValueNotifier`;
  - `authorizedHeaders()`;
  - `reportAnswer()` with a persisted queue.
- **`lib/session.dart`:**
  - uses the install id instead of a per-launch random id;
  - sends Bearer auth;
  - on 401 `token_expired`, refreshes and retries once;
  - 402 → an `OutOfCredits` result that reconnects at `resetsAt`;
  - 403 → back to the sign-in gate;
  - fixes the existing bug where a non-JSON 5xx body (`jsonDecode` before the
    status check, `session.dart:270`) escapes the reconnect path.
- **`lib/ordi/ordi_controller.dart`:**
  - reports each answered exchange;
  - adds an out-of-credits state (the session closed; no reconnect until reset
    or refresh).
- **`lib/main.dart`:**
  - a sign-in gate **before** `PairingFlow`, also shown to existing users whose
    setup is done;
  - `startGate` / `_micGate` wait for sign-in, so the first `/session` is
    authenticated.
- **New `lib/account/` screens:**
  - Email → Code (with one-time-code autofill);
  - Not an owner (store link, "try another email", support);
  - Awaiting delivery (tracking link);
  - Device limit (the two phones, "Sign out of this phone").
- **Home and Settings:**
  - the credits pill becomes real ("18 left today" / "Unlimited");
  - Settings shows email, plan, credits, reset time, devices (remove), Sign
    out, Delete account, and Upgrade only where allowed;
  - the name stays local as now.

## Also required
- **Store and legal listings:**
  - Privacy policy (`backend/token-service/src/pages.js`): it now stores
    account email, device names and daily usage counts, and "nothing is kept on
    our servers" must change.
  - App Store App Privacy: add Email Address and Product Interaction (linked,
    app functionality).
  - Play Data safety: the same.
- **App Review:** a reviewer grant plus demo instructions in review notes. The
  reviewer email's code is delivered to an inbox the team shares with Apple via
  the notes. There is no hardcoded backdoor code.
- **Secrets (Lambda env or Secrets Manager):**
  - `MONGODB_URI` (the new least-privilege user);
  - `JWT_SECRET`, `OTP_HMAC_SECRET`;
  - `RESEND_API_KEY` and a sending domain (for example
    `no-reply@ordinarywearables.com`, DNS verified);
  - Shiprocket API user and Delhivery token for delivery checks.
  - The user should also rotate the `admin` Atlas password that was shared in
    chat.
- **Atlas network access** for Lambda: either allow-list `0.0.0.0/0` with
  strong credentials, or a VPC + NAT static IP (costs money). Confirm the
  current access list.

## Rollout (no one locked out by surprise)
1. **Backend with `AUTH_REQUIRED=false`.** Old builds keep working on the
   shared key; new builds sign in.
2. **Grants.** Team and testers get grants; ship TestFlight + Play internal;
   test.
3. **Store release.** The new build goes to the App Store with reviewer notes.
4. **Enforcement.** After adoption, flip `AUTH_REQUIRED=true`. Old builds get
   `429 "Please update Ordinary to keep using it."`, which they already show
   as a permanent message.

## Files
- **Backend:**
  - `backend/token-service/src/server.js` (auth on `/session`, route wiring);
  - new `src/auth.js`, `src/entitlement.js`, `src/credits.js`, `src/db.js`,
    `src/delivery.js`, `src/mail.js`, `src/ratelimit.js`;
  - `package.json` (`mongodb`);
  - `src/pages.js`.
- **App:**
  - `lib/session.dart`, `lib/ordi/ordi_controller.dart`, `lib/main.dart`;
  - `lib/home/home_screen.dart`, `lib/settings/settings_screen.dart`;
  - new `lib/models/account.dart` and `lib/account/*`;
  - `pubspec.yaml` (`flutter_secure_storage`, `uuid`).
- **Admin:** `backend/token-service/scripts/grant.mjs` (add or revoke grants,
  block an account, list devices).

## Verification
- **Backend unit tests** (`node --test`, with mongodb-memory-server):
  - OTP send, verify, expiry, 5-try lockout, single use, cooldown;
  - `/auth/start` responses identical for known and unknown emails;
  - refresh rotation and reuse revocation;
  - device limit and replace;
  - entitlement matrix (prepaid; COD pending, delivered and RTO; paid
    subscription active and expired; grant; blocked);
  - concurrent `/usage/answer` never exceeding 25;
  - idempotent duplicates;
  - timezone day rollover;
  - 402 and 403 on `/session`;
  - `AUTH_REQUIRED` both ways.
- **Read-only entitlement dry run** against the real store DB: counts per
  outcome only (owners, awaiting delivery, paid, none), no personal data
  printed.
- **Flutter tests:**
  - sign-in screens and gate (including existing users);
  - device-limit flow;
  - 402 → out-of-credits UI and reset timer;
  - answer reporting (queue, retry, idempotent ids);
  - credits pill;
  - 401 refresh-and-retry;
  - the non-JSON 5xx fix.
  - The existing 117 tests keep passing.
- **Live:**
  - staging deploy; sign in on IP13 and the Motorola with a granted test email
    and with a real owner email;
  - use 25 answers → limit screen;
  - add a third phone → device-limit screen;
  - buy a test paid plan on the website → Unlimited shows on return;
  - the old TestFlight build still works while `AUTH_REQUIRED=false`.

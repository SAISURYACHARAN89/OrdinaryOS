import { createServer } from 'node:http';
import { GoogleGenAI } from '@google/genai';

/**
 * Ordi token service.
 *
 * Mints short-lived Gemini Live tokens so the app can talk to Google directly.
 * Audio never passes through here — a relay would add a network hop to every
 * chunk in both directions, and latency is the whole reason speech-to-speech
 * was chosen over a chained pipeline.
 *
 * What this service is actually for:
 *   1. Key custody      — the real API key never leaves this process.
 *   2. Usage metering    — a device that is out of allowance gets no token.
 *   3. Prompt custody    — the system instruction and reply-length limit are
 *                          pinned into the token's constraints, so a modified
 *                          client cannot strip them. That matters: reply
 *                          length is a 5x swing on the monthly bill.
 */

const PORT = Number(process.env.PORT ?? 8787);
const MODEL = process.env.MODEL ?? 'gemini-3.1-flash-live-preview';

// A token expires after this long, which bounds how long any one conversation
// can run. Combined with SESSIONS_PER_DAY this is what actually enforces the
// daily cap — server-side, without trusting the client to report anything.
const SESSION_MINUTES = Number(process.env.SESSION_MINUTES ?? 30);

// 0 means unlimited. Left unlimited by default so development is not annoying;
// set it (3 x 5min = the ~15 min/day product decision) before anyone else has
// the app.
const SESSIONS_PER_DAY = Number(process.env.SESSIONS_PER_DAY ?? 0);

/**
 * Shared secret the app must present.
 *
 * Unset means open, which is fine on a laptop on your own LAN and is why
 * development is not encumbered. **Set it before this is reachable from the
 * internet**: without it, anyone who finds the URL can mint tokens against the
 * Gemini key and spend your quota. It is not real authentication — the secret
 * ships inside the app and can be extracted — but it stops opportunistic abuse
 * of a URL that leaks. Real per-user auth arrives with accounts.
 */
const CLIENT_SECRET = process.env.ORDI_CLIENT_SECRET ?? '';

const API_KEY = process.env.GEMINI_API_KEY;
if (!API_KEY) {
  console.error(
    '\nGEMINI_API_KEY is not set.\n' +
    'Copy .env.example to .env and put your key in it, then run again.\n'
  );
  process.exit(1);
}

/**
 * Ordi's voice and, more importantly, its length limit.
 *
 * Output audio costs roughly 3-4x input on every provider, so how long Ordi
 * talks dominates the bill far more than which model answers. Two or three
 * sentences is a cost control, not a style note.
 */
const SYSTEM_INSTRUCTION = [
  'You are Ordi, a warm, direct, general-purpose voice assistant.',
  'You are speaking aloud in a live conversation, not writing.',
  'Keep every reply to two or three sentences.',
  'If something genuinely needs more, give the short answer first and offer to go deeper.',
  'Never use markdown, bullet points, headings, or emoji — everything you say is spoken.',
  'Do not narrate what you are about to do. Just answer.',
].join(' ');

// Ephemeral tokens exist only in v1alpha — the SDK warns and misbehaves if
// this is left on the default version.
const ai = new GoogleGenAI({
  apiKey: API_KEY,
  httpOptions: { apiVersion: 'v1alpha' },
});

/**
 * Per-device usage, in memory.
 *
 * Deliberately not a database yet: v1 has no accounts, and the daily cap was
 * accepted as bypassable for now. This resets whenever the process restarts —
 * fine for development, and the thing to replace first when this is deployed
 * anywhere real.
 */
const usage = new Map();

function today() {
  return new Date().toISOString().slice(0, 10);
}

/** Returns null when allowed, or a reason string when the device is capped. */
function claimSession(deviceId) {
  if (SESSIONS_PER_DAY <= 0) return null;

  const day = today();
  const record = usage.get(deviceId);

  if (!record || record.day !== day) {
    usage.set(deviceId, { day, count: 1 });
    return null;
  }
  if (record.count >= SESSIONS_PER_DAY) {
    return `Daily limit reached (${SESSIONS_PER_DAY} sessions).`;
  }
  record.count += 1;
  return null;
}

function remaining(deviceId) {
  if (SESSIONS_PER_DAY <= 0) return null;
  const record = usage.get(deviceId);
  if (!record || record.day !== today()) return SESSIONS_PER_DAY;
  return Math.max(0, SESSIONS_PER_DAY - record.count);
}

async function mintToken() {
  const now = Date.now();
  return ai.authTokens.create({
    config: {
      // One token, one conversation.
      uses: 1,
      // How long the session may send messages for.
      expireTime: new Date(now + SESSION_MINUTES * 60_000).toISOString(),
      // How long the app has to actually open the socket before the token dies.
      newSessionExpireTime: new Date(now + 60_000).toISOString(),
      // Pinned server-side. The client cannot change the model, ask for text
      // instead of audio, or drop the length limit.
      liveConnectConstraints: {
        model: MODEL,
        config: {
          responseModalities: ['AUDIO'],
          systemInstruction: SYSTEM_INSTRUCTION,
          sessionResumption: {},
          // Gives us the text of what Ordi is saying, so the app can show the
          // words as they are spoken — for noisy rooms, re-reading an
          // explanation, sound-off use, and accessibility.
          outputAudioTranscription: {},
        },
      },
    },
  });
}

function send(res, status, body) {
  if (status === 204) {
    res.writeHead(204);
    return res.end();
  }
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'content-type': 'application/json',
    'content-length': Buffer.byteLength(payload),
  });
  res.end(payload);
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    let raw = '';
    req.on('data', (chunk) => {
      raw += chunk;
      // Nothing legitimate is large here; refuse to buffer more.
      if (raw.length > 4096) reject(new Error('Request body too large.'));
    });
    req.on('end', () => {
      if (!raw) return resolve({});
      try {
        resolve(JSON.parse(raw));
      } catch {
        reject(new Error('Body was not valid JSON.'));
      }
    });
    req.on('error', reject);
  });
}

const server = createServer(async (req, res) => {
  if (req.method === 'GET' && req.url === '/health') {
    return send(res, 200, { ok: true, model: MODEL });
  }

  // Development telemetry. iOS device logs are not reachable from the command
  // line on current macOS, and guessing at on-device behaviour from symptoms
  // is slow and unreliable — so the app reports what it is doing here instead.
  // Remove, or gate behind a flag, before this serves real users.
  if (req.method === 'POST' && req.url === '/diag') {
    let body = {};
    try {
      body = await readJson(req);
    } catch {
      // A malformed diagnostic is not worth failing over.
    }
    const at = new Date().toISOString().slice(11, 23);
    const device = String(body.deviceId ?? '????????').slice(0, 8);
    const detail = body.detail ? ` ${JSON.stringify(body.detail)}` : '';
    console.log(`[diag ${at}] ${device} ${body.event ?? '?'}${detail}`);
    return send(res, 204, {});
  }

  if (req.method !== 'POST' || req.url !== '/session') {
    return send(res, 404, { error: 'Not found.' });
  }

  let body;
  try {
    body = await readJson(req);
  } catch (error) {
    return send(res, 400, { error: error.message });
  }

  if (CLIENT_SECRET) {
    const presented = req.headers['x-ordi-key'];
    if (presented !== CLIENT_SECRET) {
      return send(res, 401, { error: 'Not authorised.' });
    }
  }

  const deviceId = String(body.deviceId ?? '').trim();
  if (!deviceId) {
    return send(res, 400, { error: 'deviceId is required.' });
  }

  const capped = claimSession(deviceId);
  if (capped) {
    return send(res, 429, { error: capped });
  }

  try {
    const token = await mintToken();
    send(res, 200, {
      token: token.name,
      model: MODEL,
      expiresInSeconds: SESSION_MINUTES * 60,
      remainingSessions: remaining(deviceId),
    });
    console.log(`[token] issued to ${deviceId.slice(0, 8)}…`);
  } catch (error) {
    // Most failures here are billing or key problems, and the message from
    // Google is usually the useful part.
    console.error('[token] mint failed:', error?.message ?? error);
    send(res, 502, {
      error: 'Could not mint a session token.',
      detail: error?.message ?? String(error),
    });
  }
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`Ordi token service on http://0.0.0.0:${PORT}`);
  console.log(`  model            ${MODEL}`);
  console.log(`  session length   ${SESSION_MINUTES} min`);
  console.log(
    `  daily sessions   ${SESSIONS_PER_DAY > 0 ? SESSIONS_PER_DAY : 'unlimited (development)'}`
  );
  console.log(
    `  client secret    ${CLIENT_SECRET ? 'required' : 'NOT SET — open to anyone who can reach this'}`
  );
});

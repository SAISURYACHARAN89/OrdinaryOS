/**
 * End-to-end check: mint a token, open a real Live session with it, and see
 * whether Google actually answers.
 *
 * Minting a token is a cheap call that succeeds on almost any key. Opening a
 * Live session is the one that fails on an unbilled project — so this is the
 * test that tells you whether the account is genuinely ready.
 *
 *   node --env-file=.env scripts/smoke.mjs
 */
import { GoogleGenAI, Modality } from '@google/genai';

const MODEL = process.env.MODEL ?? 'gemini-3.1-flash-live-preview';
const API_KEY = process.env.GEMINI_API_KEY;

if (!API_KEY) {
  console.error('GEMINI_API_KEY is not set. Run with: node --env-file=.env scripts/smoke.mjs');
  process.exit(1);
}

const ai = new GoogleGenAI({ apiKey: API_KEY, httpOptions: { apiVersion: 'v1alpha' } });

function fail(stage, error) {
  const message = error?.message ?? String(error);
  console.error(`\nFAILED at: ${stage}\n${message}\n`);
  if (/billing|quota|PERMISSION_DENIED|FAILED_PRECONDITION/i.test(message)) {
    console.error(
      'That reads like an account problem rather than a code problem —\n' +
      'usually billing not enabled on the project behind this key.\n'
    );
  }
  process.exit(1);
}

console.log(`model: ${MODEL}`);

// 1. Mint an ephemeral token, exactly as the service does for the app.
let token;
try {
  const now = Date.now();
  token = await ai.authTokens.create({
    config: {
      uses: 1,
      expireTime: new Date(now + 10 * 60_000).toISOString(),
      newSessionExpireTime: new Date(now + 60_000).toISOString(),
      liveConnectConstraints: {
        model: MODEL,
        config: { responseModalities: ['AUDIO'] },
      },
    },
  });
  console.log(`token minted: ${String(token.name).slice(0, 14)}…`);
} catch (error) {
  fail('minting the ephemeral token', error);
}

// 2. Open a Live session using the token in place of the API key — the same
//    thing the phone will do.
const client = new GoogleGenAI({
  apiKey: token.name,
  httpOptions: { apiVersion: 'v1alpha' },
});

let audioBytes = 0;
let sawTurnComplete = false;
let closedReason = null;

const done = new Promise((resolve) => {
  const finish = () => resolve();
  setTimeout(finish, 30_000).unref?.();

  ai.live
    .connect.call(client.live, {
      model: MODEL,
      config: { responseModalities: [Modality.AUDIO] },
      callbacks: {
        onopen: () => console.log('session open'),
        onmessage: (message) => {
          const parts = message?.serverContent?.modelTurn?.parts ?? [];
          for (const part of parts) {
            const data = part?.inlineData?.data;
            if (data) audioBytes += Buffer.from(data, 'base64').length;
          }
          if (message?.serverContent?.turnComplete) {
            sawTurnComplete = true;
            finish();
          }
        },
        onerror: (error) => {
          closedReason = error?.message ?? String(error);
          finish();
        },
        onclose: (event) => {
          closedReason ??= event?.reason || null;
          finish();
        },
      },
    })
    .then((session) => {
      session.sendClientContent({
        turns: 'Say hello in five words.',
        turnComplete: true,
      });
    })
    .catch((error) => {
      closedReason = error?.message ?? String(error);
      finish();
    });
});

await done;

if (audioBytes > 0) {
  console.log(`\nOK — received ${audioBytes} bytes of audio back.`);
  console.log('The Live API works on this key. Nothing is blocking us.\n');
  process.exit(0);
}

fail(
  'opening the Live session',
  closedReason ?? `no audio received (turnComplete=${sawTurnComplete})`
);

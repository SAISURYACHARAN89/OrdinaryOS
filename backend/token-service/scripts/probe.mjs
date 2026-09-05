/**
 * Raw-socket probe: sends byte-for-byte what the Swift client sends, and
 * prints everything the server says back.
 *
 * The SDK smoke test proves the account works. This proves whether *our*
 * handwritten setup message is accepted — the two can disagree, and when they
 * do this is the one that finds it.
 *
 *   node --env-file=.env scripts/probe.mjs
 */
const PORT = process.env.PORT ?? 8787;
const res = await fetch(`http://127.0.0.1:${PORT}/session`, {
  method: 'POST',
  headers: {
    'content-type': 'application/json',
    // The service requires this once ORDI_CLIENT_SECRET is set.
    ...(process.env.ORDI_CLIENT_SECRET
      ? { 'x-ordi-key': process.env.ORDI_CLIENT_SECRET }
      : {}),
  },
  body: JSON.stringify({ deviceId: 'probe' }),
});
const { token, model, error, detail } = await res.json();
if (!token) {
  console.error('no token:', error ?? detail);
  process.exit(1);
}
console.log(`token ${String(token).slice(0, 14)}…  model ${model}`);

const url =
  'wss://generativelanguage.googleapis.com/ws/' +
  'google.ai.generativelanguage.v1alpha.GenerativeService' +
  `.BidiGenerateContentConstrained?access_token=${token}`;

const ws = new WebSocket(url);
let sawSetupComplete = false;

ws.addEventListener('open', () => {
  console.log('socket OPEN');
  // Exactly what GeminiLiveSession.sendSetup() builds.
  const setup = {
    setup: {
      model: `models/${model}`,
      generationConfig: { responseModalities: ['AUDIO'] },
      outputAudioTranscription: {},
    },
  };
  console.log('-> setup:', JSON.stringify(setup));
  ws.send(JSON.stringify(setup));
});

ws.addEventListener('message', async (event) => {
  const raw =
    typeof event.data === 'string'
      ? event.data
      : Buffer.from(await event.data.arrayBuffer()).toString('utf8');
  const short = raw.length > 400 ? raw.slice(0, 400) + `… (${raw.length}B)` : raw;
  console.log('<-', short);
  if (raw.includes('setupComplete')) {
    sawSetupComplete = true;
    console.log('   [setup accepted — sending a text turn to force a reply]');
    ws.send(JSON.stringify({
      clientContent: {
        turns: [{ role: 'user', parts: [{ text: 'Say hello in five words.' }] }],
        turnComplete: true,
      },
    }));
  }
});

ws.addEventListener('error', (e) => console.log('SOCKET ERROR:', e.message ?? e));
ws.addEventListener('close', (e) => {
  console.log(`socket CLOSED code=${e.code} reason="${e.reason}"`);
  console.log(sawSetupComplete ? 'setup was accepted' : 'SETUP WAS NEVER ACCEPTED');
  process.exit(0);
});

setTimeout(() => { console.log('(timeout)'); ws.close(); }, 25_000);

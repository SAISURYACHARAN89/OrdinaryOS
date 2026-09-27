/**
 * Measures how the Live API behaves when the app stops streaming audio in
 * between utterances — the question the on-device speech gate and wake word
 * depend on. Uses real speech (16 kHz mono WAV, e.g. from macOS `say` +
 * `afconvert -f WAVE -d LEI16@16000 -c 1`). Prints no secrets.
 *
 *   node --env-file=.env scripts/gate-probe.mjs <clips-dir> [case ...]
 *
 * Cases:
 *   baseline  clip streamed in real time, 1.5 s silence, audioStreamEnd
 *   burst     session idle 20 s, then clip sent as one burst (pre-roll),
 *             1.5 s silence in real time, audioStreamEnd
 *   noTail    burst, then audioStreamEnd straight away, no trailing silence
 *   followup  burst question, answer, then a second question 3 s later
 *   chatter   burst of overheard talk (must stay silent)
 *   silence   60 s of silence streamed in real time, then a burst question
 *             (is streamed silence billed? compare AUDIO prompt tokens)
 *   growth    12 overheard sentences in one session, one after another:
 *             how the re-billed history grows turn by turn
 *   keepalive 100 ms of silence every KEEPALIVE_S seconds (default 20) for
 *             KEEPALIVE_MIN minutes (default 5), then a burst question: does a
 *             sparse keep-alive stop the ~150 s idle abort, and is it free?
 *   idle      no audio at all for IDLE_MIN minutes (default 11), then a burst
 *             question
 *
 * Reports per case: what the model heard (input transcription), whether and
 * how fast it answered after the last audio was sent, tools called, and the
 * usageMetadata it reported per turn.
 */
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const BASE = process.env.BASE ?? 'https://oyurx6vlprfvlq44qvj4zjwop40rhtwk.lambda-url.ap-south-1.on.aws';
const dir = process.argv[2];
if (!dir) throw new Error('usage: gate-probe.mjs <clips-dir> [case ...]');

function pcm(name) {
  const buf = readFileSync(join(dir, `${name}.wav`));
  // Find the "data" chunk rather than assuming a 44-byte header.
  let i = 12;
  while (i < buf.length - 8) {
    const id = buf.toString('ascii', i, i + 4);
    const size = buf.readUInt32LE(i + 4);
    if (id === 'data') return buf.subarray(i + 8, i + 8 + size);
    i += 8 + size + (size % 2);
  }
  throw new Error(`no data chunk in ${name}.wav`);
}

const CHUNK = 3200; // 100 ms of 16 kHz Int16
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const silence = Buffer.alloc(CHUNK);

async function open() {
  const res = await fetch(`${BASE}/session`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-ordi-key': process.env.ORDI_CLIENT_SECRET ?? '' },
    body: JSON.stringify({ deviceId: 'gate-probe', tools: true, toolsV2: true, toolsV3: true, toolsV4: true, now: new Date().toISOString(), ...(process.env.MEMORY ? { memory: process.env.MEMORY } : {}) }),
  });
  const { token, model, error } = await res.json();
  if (!token) throw new Error(`no token: ${error}`);
  const ws = new WebSocket(
    'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.' +
      `GenerativeService.BidiGenerateContentConstrained?access_token=${token}`,
  );
  const log = { heard: '', said: '', tools: [], usage: [], firstAudioAt: null, turns: 0, closed: null, goAway: null };
  const opened = Date.now();
  await new Promise((resolve, reject) => {
    ws.addEventListener('open', () =>
      ws.send(JSON.stringify({ setup: { model: `models/${model}` } })));
    ws.addEventListener('message', async (ev) => {
      const raw = typeof ev.data === 'string' ? ev.data : Buffer.from(await ev.data.arrayBuffer()).toString('utf8');
      let r;
      try { r = JSON.parse(raw); } catch { return; }
      if (r.setupComplete) resolve();
      if (r.goAway) log.goAway = Math.round((Date.now() - opened) / 1000);
      if (r.usageMetadata) log.usage.push(r.usageMetadata);
      if (r.toolCall) {
        const calls = r.toolCall.functionCalls ?? [];
        for (const c of calls) log.tools.push(c.name);
        ws.send(JSON.stringify({ toolResponse: { functionResponses: calls.map((c) => ({ id: c.id, name: c.name, response: { result: 'ok' } })) } }));
      }
      const c = r.serverContent;
      if (!c) return;
      if (c.inputTranscription?.text) log.heard += c.inputTranscription.text;
      if (c.outputTranscription?.text) log.said += c.outputTranscription.text;
      if (!log.firstAudioAt && c.modelTurn?.parts?.some((p) => p.inlineData)) log.firstAudioAt = Date.now();
      if (c.turnComplete) log.turns++;
    });
    ws.addEventListener('close', (e) => { log.closed = `${e.code} ${e.reason}`.slice(0, 120); reject(new Error('closed before ready')); });
    ws.addEventListener('error', () => reject(new Error('socket error')));
  });
  const send = (b) => ws.send(JSON.stringify({ realtimeInput: { audio: { data: b.toString('base64'), mimeType: 'audio/pcm;rate=16000' } } }));
  const streamEnd = () => ws.send(JSON.stringify({ realtimeInput: { audioStreamEnd: true } }));
  return { ws, log, send, streamEnd };
}

async function realtime(s, buf) {
  for (let o = 0; o < buf.length; o += CHUNK) { s.send(buf.subarray(o, o + CHUNK)); await sleep(100); }
}
function burst(s, buf) {
  for (let o = 0; o < buf.length; o += CHUNK) s.send(buf.subarray(o, o + CHUNK));
}
async function tail(s, ms = 1500) {
  for (let t = 0; t < ms; t += 100) { s.send(silence); await sleep(100); }
}
async function waitAnswer(s, ms = 12000) {
  const start = Date.now();
  while (Date.now() - start < ms && s.log.turns === 0) await sleep(100);
  await sleep(800);
}

const CASES = {
  async baseline() {
    const s = await open();
    await realtime(s, pcm('q1'));
    await tail(s);
    s.streamEnd();
    const sentAt = Date.now();
    await waitAnswer(s);
    return { s, sentAt };
  },
  async burst() {
    const s = await open();
    await sleep(20000);
    burst(s, pcm('q1'));
    await tail(s);
    s.streamEnd();
    const sentAt = Date.now();
    await waitAnswer(s);
    return { s, sentAt };
  },
  async noTail() {
    const s = await open();
    burst(s, pcm('q1'));
    s.streamEnd();
    const sentAt = Date.now();
    await waitAnswer(s);
    return { s, sentAt };
  },
  async followup() {
    const s = await open();
    burst(s, pcm('q1'));
    await tail(s);
    s.streamEnd();
    await waitAnswer(s);
    await sleep(3000);
    s.log.firstAudioAt = null;
    const before = s.log.turns;
    burst(s, pcm('q2'));
    await tail(s);
    s.streamEnd();
    const sentAt = Date.now();
    const start = Date.now();
    while (Date.now() - start < 12000 && s.log.turns === before) await sleep(100);
    await sleep(800);
    return { s, sentAt };
  },
  async chatter() {
    const s = await open();
    burst(s, pcm('chat'));
    await tail(s);
    s.streamEnd();
    const sentAt = Date.now();
    await waitAnswer(s, 8000);
    return { s, sentAt };
  },
  async silence() {
    const s = await open();
    await tail(s, 60000);
    burst(s, pcm('q1'));
    await tail(s);
    s.streamEnd();
    const sentAt = Date.now();
    await waitAnswer(s);
    return { s, sentAt };
  },
  async growth() {
    const s = await open();
    for (let i = 0; i < Number(process.env.TURNS ?? 12); i++) {
      const before = s.log.turns;
      burst(s, pcm('chat'));
      await tail(s);
      s.streamEnd();
      const start = Date.now();
      while (Date.now() - start < 10000 && s.log.turns === before) await sleep(100);
      await sleep(300);
    }
    const sentAt = Date.now();
    return { s, sentAt };
  },
  async keepalive() {
    const s = await open();
    const every = Number(process.env.KEEPALIVE_S ?? 20) * 1000;
    const minutes = Number(process.env.KEEPALIVE_MIN ?? 5);
    const opened = Date.now();
    s.ws.addEventListener('close', (e) => {
      console.log(`          session closed after ${Math.round((Date.now() - opened) / 1000)} s: ${e.code} ${String(e.reason).slice(0, 100)}`);
    });
    while (Date.now() - opened < minutes * 60 * 1000) {
      s.send(silence);
      await sleep(every);
    }
    burst(s, pcm('q1'));
    await tail(s);
    s.streamEnd();
    const sentAt = Date.now();
    await waitAnswer(s);
    return { s, sentAt };
  },
  async idle() {
    const s = await open();
    const minutes = Number(process.env.IDLE_MIN ?? 11);
    const opened = Date.now();
    s.ws.addEventListener('close', (e) => {
      console.log(`          idle session closed after ${Math.round((Date.now() - opened) / 1000)} s: ${e.code} ${String(e.reason).slice(0, 100)}`);
    });
    await sleep(minutes * 60 * 1000);
    burst(s, pcm('q1'));
    await tail(s);
    s.streamEnd();
    const sentAt = Date.now();
    await waitAnswer(s);
    return { s, sentAt };
  },
};

const wanted = process.argv.slice(3).length ? process.argv.slice(3) : ['baseline', 'burst', 'noTail', 'followup', 'chatter'];
for (const name of wanted) {
  try {
    const { s, sentAt } = await CASES[name]();
    const lat = s.log.firstAudioAt ? `${s.log.firstAudioAt - sentAt} ms` : 'no audio';
    const u = s.log.usage.map((m) => {
      const by = Object.fromEntries((m.promptTokensDetails ?? []).map((d) => [d.modality, d.tokenCount]));
      return `prompt=${m.promptTokenCount ?? '?'} (text ${by.TEXT ?? 0}, audio ${by.AUDIO ?? 0}) out=${m.responseTokenCount ?? '?'}`;
    });
    console.log(`${name.padEnd(9)} answered=${s.log.said.trim().length > 0} latency=${lat} tools=[${s.log.tools}] goAway=${s.log.goAway ?? '-'}`);
    console.log(`          heard: ${s.log.heard.trim().slice(0, 90)}`);
    console.log(`          said:  ${s.log.said.trim().slice(0, 90)}`);
    if (u.length) console.log(`          usage: ${u.join(' | ')}`);
    s.ws.close();
  } catch (e) {
    console.log(`${name.padEnd(9)} ERROR ${e.message}`);
  }
}
process.exit(0);

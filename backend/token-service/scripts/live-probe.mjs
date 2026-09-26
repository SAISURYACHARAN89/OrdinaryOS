/**
 * Behaviour checks against the real model, through a running token service.
 *
 * Each case opens a fresh session exactly as the app does, types one or more
 * turns, answers any tool call with a canned result, and checks which tools
 * were called and what Ordi said. Prints no secrets.
 *
 *   PORT=8788 node --env-file=.env src/server.js &
 *   node --env-file=.env scripts/live-probe.mjs [suite ...]
 *   BASE=https://<function-url> node --env-file=.env scripts/live-probe.mjs
 *
 * Suites: wake, reminders, app, recording, english. No arguments runs all.
 */
const BASE = process.env.BASE ?? 'http://127.0.0.1:8788';
const CLIENT = { tools: true, toolsV2: true, toolsV3: true, toolsV4: true };

const pad = (n) => String(n).padStart(2, '0');
function localIso() {
  const d = new Date();
  const off = -d.getTimezoneOffset();
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}` +
    `T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}` +
    `${off >= 0 ? '+' : '-'}${pad(Math.floor(Math.abs(off) / 60))}:${pad(Math.abs(off) % 60)}`;
}

/** Canned tool results, shaped like what the app returns. */
const CANNED = {
  create_reminder: 'Reminder set for Today, 5:00 PM.',
  update_reminder: 'Moved "Call mom" to Today, 3:00 PM.',
  cancel_reminder: 'Cancelled "Call mom".',
  list_reminders: '3 in total: Call mom — today at 5:00 PM; Buy milk — today at 7:00 PM; Renew passport (no time).',
  cancel_all_reminders: 'Deleted 3 reminders.',
  list_recordings: '2 recordings, newest first: Weekly standup, Today, 3:07 PM; Lunch with Ravi, Yesterday, 1:10 PM.',
  delete_recording: 'Deleted "Weekly standup".',
  list_contacts: 'On speed dial: Charan, Mom, Krishna.',
  open_study_mode: { opened: false, say_this: 'The study mode is specific to your Ordinary Band. Connect your Band to use study mode and upload your notes in the app.' },
  start_recording: 'Recording started. Confirm it in one short sentence, then carry on exactly as usual.',
  stop_recording: 'Stopped after 2 minutes, 4 things said.',
  recall_recording: 'Weekly standup, from Today, 3:07 PM. Release blockers reviewed.',
  call_contact: 'Opening the phone to call Charan.',
  stay_silent: 'ok',
};

export async function session(turns, extra = {}) {
  const res = await fetch(`${BASE}/session`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      ...(process.env.ORDI_CLIENT_SECRET ? { 'x-ordi-key': process.env.ORDI_CLIENT_SECRET } : {}),
    },
    body: JSON.stringify({ deviceId: 'live-probe', now: localIso(), ...CLIENT, ...extra }),
  });
  const { token, model, error } = await res.json();
  if (!token) throw new Error(`no token: ${error}`);
  const ws = new WebSocket(
    'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.' +
      `GenerativeService.BidiGenerateContentConstrained?access_token=${token}`,
  );
  const log = [];
  let i = 0;
  return new Promise((resolve) => {
    const next = () => {
      if (i >= turns.length) return ws.close();
      const text = turns[i++];
      log.push({ user: text, tools: [], said: '' });
      ws.send(JSON.stringify({ clientContent: { turns: [{ role: 'user', parts: [{ text }] }], turnComplete: true } }));
    };
    ws.addEventListener('open', () =>
      ws.send(JSON.stringify({ setup: { model: `models/${model}`, generationConfig: { responseModalities: ['AUDIO'] }, outputAudioTranscription: {} } })));
    ws.addEventListener('message', async (ev) => {
      const raw = typeof ev.data === 'string' ? ev.data : Buffer.from(await ev.data.arrayBuffer()).toString('utf8');
      let r;
      try { r = JSON.parse(raw); } catch { return; }
      if (r.setupComplete) return next();
      if (r.toolCall) {
        const calls = r.toolCall.functionCalls ?? [];
        for (const c of calls) log[log.length - 1].tools.push({ name: c.name, args: c.args ?? {} });
        ws.send(JSON.stringify({ toolResponse: { functionResponses: calls.map((c) => ({ id: c.id, name: c.name, response: typeof CANNED[c.name] === 'object' ? CANNED[c.name] : { result: CANNED[c.name] ?? 'ok' } })) } }));
        if (calls.every((c) => c.name === 'stay_silent')) setTimeout(next, 1500);
        return;
      }
      const c = r.serverContent;
      if (!c) return;
      if (c.outputTranscription?.text) log[log.length - 1].said += c.outputTranscription.text;
      if (c.turnComplete) setTimeout(next, 600);
    });
    ws.addEventListener('close', () => resolve(log));
    ws.addEventListener('error', () => resolve(log));
    setTimeout(() => ws.close(), 60_000);
  });
}

const hindiish = (t) => /[ऀ-ॿ]/.test(t) || /\b(namaste|aap|kaise|hain|kya)\b/i.test(t);

/** [expected tool, or 'speak' / 'english', utterance, extra request fields] */
const SUITES = {
  wake: [
    ['stay_silent', 'So anyway I told him the meeting got moved to four and he just laughed.'],
    ['stay_silent', 'Can you pass me the charger? It is behind the sofa somewhere.'],
    ['stay_silent', 'Remind me to call the dentist tomorrow, I keep forgetting.'],
    ['speak', 'Hey Ordinary, what is two plus two?'],
    ['speak', '[ordi] remind: Call the dentist'],
    ['call_contact', 'Hey Ordinary, call Charan.'],
  ],
  reminders: [
    ['create_reminder', 'Hey Ordi, remind me to drink water in 2 minutes.'],
    ['create_reminder', 'Hey Ordi, remind me to call mom at 11 pm.'],
  ],
  app: [
    ['list_reminders', 'Hey Ordinary, what are my reminders today?'],
    ['list_reminders', 'Ordi, what do I have coming up?'],
    ['cancel_all_reminders', 'Hey Ordi, delete all my reminders.'],
    ['open_study_mode', 'Hey Ordi, study mode.'],
    ['open_study_mode', 'Ordi, open study mode please.'],
    ['list_recordings', 'Hey Ordi, what have I recorded so far?'],
    ['delete_recording', 'Hey Ordi, delete my last recording.'],
    ['list_contacts', 'Ordi, who is on my speed dial?'],
    ['stay_silent', 'Did you check your reminders today? I have so many.'],
  ],
  english: [
    ['english', '[ordi] hello', { voice: 'Sulafat', accent: 'indian' }],
    ['english', '[ordi] hello', { voice: 'Orus', accent: 'indian' }],
  ],
};

async function run(name) {
  let pass = 0;
  for (const [want, text, extra] of SUITES[name]) {
    const [l] = await session([text], extra);
    const tools = l.tools.map((t) => t.name);
    const spoke = l.said.trim().length > 0;
    const ok =
      want === 'open_study_mode' ? tools.includes(want) && !/\bopen(ed)?\b.*study|study mode is (now )?open/i.test(l.said)
      : want === 'speak' ? spoke && !tools.includes('stay_silent')
      : want === 'english' ? spoke && !hindiish(l.said)
      : want === 'stay_silent' ? tools.includes('stay_silent') && !spoke
      : tools.includes(want);
    pass += ok;
    const args = l.tools.find((t) => t.name === want)?.args;
    console.log(`${ok ? 'ok  ' : 'FAIL'} ${name.padEnd(9)} want=${want.padEnd(20)} tools=[${tools}]` +
      `${args && Object.keys(args).length ? ' ' + JSON.stringify(args) : ''} | ${l.said.trim().slice(0, 80)}`);
  }
  return [pass, SUITES[name].length];
}

const wanted = process.argv.slice(2).length ? process.argv.slice(2) : Object.keys(SUITES);
let pass = 0, total = 0;
for (const name of wanted) {
  const [p, t] = await run(name);
  pass += p; total += t;
}
console.log(`\n${pass}/${total} passed`);
process.exit(pass === total ? 0 : 1);

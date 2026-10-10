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
 * Suites: name, wake, reminders, app, traps, followup, english, docs, doctraps, clock, people. No arguments runs all.
 */
const BASE = process.env.BASE ?? 'http://127.0.0.1:8788';
const CLIENT = { tools: true, toolsV2: true, toolsV3: true, toolsV4: true, toolsV6: true };

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
  // Deliberately not the real time: an answer with it came from the tool.
  current_time: { time: '9:47 PM', date: 'Sunday 4 October 2026' },
  search_documents: {
    results: [
      { document: 'Rental Agreement 2026', page: 3, text: 'The tenant shall pay a refundable security deposit of Rs 50,000 before moving in. Pets are allowed only with written permission from the owner.' },
      { document: 'Chemistry Chapter 4 Buffers', page: 2, text: 'A buffer solution resists changes in pH when small amounts of acid or base are added. It is made from a weak acid and its conjugate base.' },
    ],
  },
};

/** What a build sends when the person has added documents. */
const DOCS = { toolsV5: true, documents: true, documentTitles: ['Rental Agreement 2026', 'Chemistry Chapter 4 Buffers'] };

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
  name: [
    ['speak', 'Ordinary, what is the capital of Japan?'],
    ['stay_silent', 'Hey Ordi, what time is it?'],
    ['stay_silent', 'Ordi, call Charan.'],
    ['stay_silent', 'Hey Ordi, remind me to call mom at six.'],
    ['stay_silent', 'It was a pretty ordinary day at work, nothing special.'],
    ['stay_silent', 'Honestly that movie was so ordinary, I expected more.'],
    ['ordinary', '[ordi] hello'],
    ['speak', 'हे ऑर्डिनरी, भारत की राजधानी क्या है?'],
    ['speak', 'Hey Ordinary yaar, kal ka weather kaisa rahega?'],
  ],
  wake: [
    ['stay_silent', 'So anyway I told him the meeting got moved to four and he just laughed.'],
    ['stay_silent', 'Can you pass me the charger? It is behind the sofa somewhere.'],
    ['stay_silent', 'Remind me to call the dentist tomorrow, I keep forgetting.'],
    ['speak', 'Hey Ordinary, what is two plus two?'],
    ['speak', '[ordi] remind: Call the dentist'],
    ['call_contact', 'Hey Ordinary, call Charan.'],
  ],
  reminders: [
    ['create_reminder', 'Hey Ordinary, remind me to drink water in 2 minutes.'],
    ['create_reminder', 'Hey Ordinary, remind me to call mom at 11 pm.'],
  ],
  app: [
    ['list_reminders', 'Hey Ordinary, what are my reminders today?'],
    ['list_reminders', 'Ordinary, what do I have coming up?'],
    ['cancel_all_reminders', 'Hey Ordinary, delete all my reminders.'],
    ['open_study_mode', 'Hey Ordinary, study mode.'],
    ['open_study_mode', 'Ordinary, open study mode please.'],
    ['list_recordings', 'Hey Ordinary, what have I recorded so far?'],
    ['delete_recording', 'Hey Ordinary, delete my last recording.'],
    ['list_contacts', 'Ordinary, who is on my speed dial?'],
    ['stay_silent', 'Did you check your reminders today? I have so many.'],
  ],
  traps: [
    ['stay_silent', 'Did you check your reminders today? I have so many.'],
    ['stay_silent', 'What have you recorded on that thing so far?'],
    ['stay_silent', 'Who is on your speed dial, just curious.'],
    ['stay_silent', 'Delete all my old reminders, I keep telling you.'],
    ['stay_silent', 'Are you going to study mode later with the kids?'],
    ['stay_silent', 'Call Charan and tell him I am late.'],
    ['stay_silent', 'The chemistry chapter on buffers is so long, I gave up.'],
  ],
  // The same kind of overheard talk, for someone who has documents.
  doctraps: [
    ['stay_silent', 'The chemistry chapter on buffers is so long, I gave up.', DOCS],
    ['stay_silent', 'What does your rental agreement say about pets, do you know?', DOCS],
    ['stay_silent', 'Check my notes for the meeting time, would you? I am driving.', DOCS],
    ['stay_silent', 'Did you read the PDF I sent you about the deposit?', DOCS],
    ['stay_silent', 'I need to study that chapter again before the exam.', DOCS],
    ['stay_silent', 'Look it up in the document, it is on page three.', DOCS],
  ],
  // 'clock:<regex>' = asked the phone, and said what it returned.
  // 'noclock' = answered aloud without asking the phone the time.
  clock: [
    ['clock:9[:. ]?47|nine forty', 'Hey Ordinary, what time is it?'],
    ['clock:9[:. ]?47|nine forty', 'Ordinary, what is the time right now?'],
    ['clock:sunday', 'Hey Ordinary, what day is it today?'],
    ['clock:october', 'Ordinary, what is the date today?'],
    ['clock:9[:. ]?47|nine forty', ['Hey Ordinary, what is the capital of Japan?', 'And what time is it now?']],
    ['noclock', 'Hey Ordinary, what is the capital of Japan?'],
    ['create_reminder', 'Hey Ordinary, remind me to call mom in ten minutes.'],
    ['create_reminder', 'Hey Ordinary, remind me to pay the rent at 6 pm.'],
    ['stay_silent', 'What time is it? We are going to be late.'],
    ['stay_silent', 'Do you have the time?'],
    ['stay_silent', 'What time does the movie start tonight?'],
    ['stay_silent', 'What is the date today, is it the fourth?'],
  ],
  // The person's name comes from the app's profile. 'name:<regex>' = it said
  // that name; 'noordinary' = answered aloud, and neither addressed the person
  // as "Ordinary" nor ended on it.
  people: [
    ['name:priya', 'Hey Ordinary, what is my name?', { name: 'Priya' }],
    ['name:priya', 'Ordinary, do you know who I am?', { name: 'Priya' }],
    ['noordinary', 'Hey Ordinary, what is the capital of Japan?', { name: 'Priya' }],
    ['noordinary', 'Hey Ordinary, what is two plus two?', { name: 'Priya' }],
    ['noordinary', 'Hey Ordinary, remind me to call mom in ten minutes.', { name: 'Priya' }],
    ['noordinary', 'Hey Ordinary, what is the capital of Japan?'],
    ['noordinary', 'Hey Ordinary, who are you?'],
    ['noname', 'Hey Ordinary, what is my name?'],
    ['noname', 'Ordinary, what is my name?', { name: '' }],
  ],
  followup: [
    ['cancel_all_reminders', ['Hey Ordinary, what are my reminders today?', 'Okay, delete them all.']],
    ['call_contact', ['Hey Ordinary, who is on my speed dial?', 'Call Charan then.']],
    ['speak', ['Hey Ordinary, what is the capital of Japan?', 'And roughly how many people live there?']],
  ],
  english: [
    ['english', '[ordi] hello', { voice: 'Sulafat', accent: 'indian' }],
    ['english', '[ordi] hello', { voice: 'Orus', accent: 'indian' }],
  ],
  // 'docs:<regex>' = searched, and the answer used what came back.
  // 'nosearch' = answered aloud without searching.
  docs: [
    ['docs:50,?000|fifty thousand', 'Hey Ordinary, how much is the security deposit in my rental agreement?', DOCS],
    ['docs:acid|pH|base', 'Ordinary, what does my chemistry chapter say about buffer solutions?', DOCS],
    ['docs:permission|owner', 'Hey Ordinary, check my documents, am I allowed to keep a pet?', DOCS],
    ['said:rental|agreement', ['Hey Ordinary, how much is the security deposit in my rental agreement?', 'Which document was that from?'], DOCS],
    ['nosearch', 'Hey Ordinary, what is the capital of Japan?', DOCS],
    ['nosearch', 'Ordinary, what is fifteen times twelve?', DOCS],
    ['create_reminder', 'Hey Ordinary, remind me to pay the rent at 6 pm.', DOCS],
    ['stay_silent', 'What does your rental agreement say about pets, do you know?', DOCS],
    ['stay_silent', 'Check my notes for the meeting time, would you? I am driving.', DOCS],
    ['stay_silent', 'The chemistry chapter on buffers is so long, I gave up.', DOCS],
    // Someone with no documents is never offered the tool, and still answers.
    ['nosearch', 'Hey Ordinary, check my documents for the deposit amount.'],
  ],
};

async function run(name) {
  let pass = 0;
  for (const [want, text, extra] of SUITES[name]) {
    // A list of turns is a conversation; only the last turn is judged.
    const turns = Array.isArray(text) ? text : [text];
    const log = await session(turns, extra);
    const l = log[log.length - 1] ?? { tools: [], said: '' };
    const tools = l.tools.map((t) => t.name);
    const spoke = l.said.trim().length > 0;
    const ok =
      want === 'open_study_mode' ? tools.includes(want) && !/\bopen(ed)?\b.*study|study mode is (now )?open/i.test(l.said)
      : want === 'speak' ? spoke && !tools.includes('stay_silent')
      : want === 'english' ? spoke && !hindiish(l.said)
      : want === 'ordinary' ? spoke && /\bordinary\b/i.test(l.said) && !/\bordi\b/i.test(l.said)
      : want === 'stay_silent' ? tools.includes('stay_silent') && !spoke && !tools.includes('search_documents') && !tools.includes('current_time')
      : want === 'nosearch' ? spoke && !tools.includes('search_documents') && !tools.includes('stay_silent')
      : want.startsWith('name:') ? spoke && new RegExp(want.slice(5), 'i').test(l.said)
      : want === 'noordinary' ? spoke && !/\bordinary[.!?,]?\s*$/i.test(l.said.trim()) && !/,\s*ordinary\b/i.test(l.said)
      : want === 'noname' ? spoke && !/\bordinary\b[.!?]?\s*$/i.test(l.said.trim()) && !/your name is ordinary|you are ordinary|you're ordinary|called ordinary/i.test(l.said)
      : want === 'noclock' ? spoke && !tools.includes('current_time') && !tools.includes('stay_silent')
      : want.startsWith('clock:') ? tools.includes('current_time') && new RegExp(want.slice(6), 'i').test(l.said)
      : want.startsWith('said:') ? spoke && new RegExp(want.slice(5), 'i').test(l.said)
      : want.startsWith('docs:') ? tools.includes('search_documents') && new RegExp(want.slice(5), 'i').test(l.said)
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

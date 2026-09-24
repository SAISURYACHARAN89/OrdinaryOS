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

/**
 * Model used for one-shot text work — summarising a finished conversation
 * and pulling tasks out of it. Deliberately separate from the Live model
 * above: this is a plain text-in/text-out call, not a speech session, and the
 * "-latest" alias means it keeps up automatically rather than needing a
 * version bump here every time the live model does.
 */
const SUMMARY_MODEL = process.env.SUMMARY_MODEL ?? 'gemini-flash-latest';

/**
 * Which voice Ordi speaks with.
 *
 * Without this the model picks one per session, so Ordi sounds like a
 * different person every time you open the app — which is fatal to the idea
 * that you are talking to someone rather than something.
 *
 * Google documents 30 voices by character but not by gender. Male-sounding
 * options in common use: Charon (informative), Orus (firm), Puck (upbeat),
 * Iapetus (clear), Achird (friendly), Gacrux (mature). Female-sounding:
 * Kore (firm), Zephyr (bright), Aoede (breezy), Leda (youthful), Sulafat
 * (warm). Audition them in AI Studio and set VOICE to switch.
 */
const VOICE = process.env.VOICE ?? 'Charon';

/**
 * The voices a user may pick, by Google's own one-word character. Anything not
 * in this list is ignored and the default is used — the client names a voice,
 * it does not get to pass arbitrary strings into the pinned token config.
 */
const VOICES = [
  'Zephyr', 'Puck', 'Charon', 'Kore', 'Fenrir', 'Leda', 'Orus', 'Aoede',
  'Callirrhoe', 'Autonoe', 'Enceladus', 'Iapetus', 'Umbriel', 'Algieba',
  'Despina', 'Erinome', 'Algenib', 'Rasalgethi', 'Laomedeia', 'Achernar',
  'Alnilam', 'Schedar', 'Gacrux', 'Pulcherrima', 'Achird', 'Zubenelgenubi',
  'Vindemiatrix', 'Sadachbia', 'Sadaltager', 'Sulafat',
];

/**
 * Languages a user can say they mainly speak. This is only a *hint* to the
 * model — it always follows whatever language it actually hears — so a person
 * who never opens the setting is not worse off. Names, not codes, because the
 * name goes straight into the prompt.
 */
const LANGUAGES = [
  'English', 'Hindi', 'Bengali', 'Telugu', 'Marathi', 'Tamil', 'Gujarati',
  'Urdu', 'Kannada', 'Odia', 'Malayalam', 'Punjabi', 'Assamese', 'Nepali',
  'Sanskrit', 'Konkani', 'Maithili', 'Sindhi', 'Kashmiri', 'Dogri',
];

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
  '',
  // The gate goes first, and it is expressed as a *tool call* rather than as
  // an instruction to stay quiet. That is not a stylistic choice — it is the
  // only formulation that works. Measured on this model over ten utterances:
  // telling it to output nothing kept it quiet in 0 of 6 room-chatter cases
  // (it answered "can you pass me the charger", and even acted on "remind me
  // to call the dentist" said to someone else), whether the rule led the
  // prompt or trailed it. Giving silence a tool name scored 10 of 10 — and
  // generated zero output audio, so it is also the cheaper of the two.
  // A chat model is bad at producing nothing and good at taking an action.
  'THE FIRST THING YOU DO ON EVERY TURN IS DECIDE WHETHER YOU WERE ADDRESSED.',
  "This person's microphone is open all day. Most of what you hear is them",
  'talking to other people, or to themselves, in a room you are not part of.',
  'You were addressed only if (a) they said your name — "Ordi", "Ordinary",',
  '"Hey Ordi", "Hey Ordinary" — in what you just heard, or (b) you spoke a',
  'moment ago and this is plainly their reply to you.',
  '',
  'If you were NOT addressed, call the stay_silent tool and say nothing at all.',
  'That is the whole turn. Do not speak before calling it, do not speak after',
  'calling it, do not explain. stay_silent IS your response.',
  'Overhearing a question is not being asked one. "Can you pass me the',
  'charger", "what time does it land", "remind me to call him" said to another',
  'person are all stay_silent, however helpful you could have been.',
  'You will call stay_silent far more often than you speak. That is correct.',
  '',
  'If you WERE addressed, answer normally.',
  'You are speaking aloud in a live conversation, not writing.',
  'Keep every reply to two or three sentences.',
  'If something genuinely needs more, give the short answer first and offer to go deeper.',
  'Never use markdown, bullet points, headings, or emoji — everything you say is spoken.',
  'Do not narrate what you are about to do. Just answer.',
  '',
  'YOUR OTHER TOOLS. Every one of them is gated behind the rule above: if you',
  'were not addressed, the answer is stay_silent, even when the words you',
  'heard describe something a tool could do. Hearing "remind me to call the',
  'dentist" across the room is not an instruction to you.',
  'When you WERE addressed, use them the moment they are asked for, in the',
  'same turn, and confirm in one short spoken sentence afterwards. Never say',
  'you will do something and then not call the tool.',
  'create_reminder: whenever they ask to be reminded of something, or say they',
  'must not forget it. Resolve times against the current time given below and',
  'pass a full date and time. If they gave no time at all, omit it.',
  'start_recording and stop_recording: when they ask you to record, capture, or',
  'take notes on a conversation, meeting, or their day.',
  'WHILE A RECORDING IS RUNNING you are a silent witness: call stay_silent for',
  'everything you hear, with no exceptions, until they address you by name',
  'again or ask you to stop recording. This is the whole point of the mode —',
  'they are talking to other people and you are taking notes.',
  'recall_recording: when they ask what was said in a past conversation,',
  'meeting, or recording. Read the summary it returns back to them in your own',
  'words, and answer follow-up questions from it.',
  'call_contact: when they ask you to call, phone, dial or ring someone.',
  '',
  // The app injects these as ordinary user turns because that is the only
  // inbound channel there is. Without this clause the wake gate above would
  // correctly decide nobody addressed Ordi and silently swallow them.
  'MESSAGES BEGINNING WITH [ordi] ARE FROM THE APP, NOT THE PERSON.',
  'They are not speech and were not overheard, so the silence rule does not',
  'apply to them — always act on one. "[ordi] remind: X" means a reminder they',
  'set has just come due: tell them about X in one short, natural sentence, as',
  'if you had remembered it. "[ordi] hello" means they have just chosen your',
  'voice in settings: say one short, friendly sentence introducing yourself,',
  'so they can hear how you sound. Never read the [ordi] marker out, never',
  'mention the app told you, and never call a tool in response to one.',
].join(' ');

/**
 * Appended for every client that gets the gated prompt. Multilingual by
 * instruction rather than by configuration: the Live model detects the spoken
 * language itself, so there is no language code to pin — this only tells it to
 * follow the person instead of defaulting to English, and that a transliterated
 * or accented "Ordi" still counts as being addressed.
 */
const LANGUAGE_CLAUSE = [
  'LANGUAGE.',
  'People speak to you in many languages, often mixing two in one sentence —',
  'Hinglish, Tanglish and the like. Understand whatever you hear, including',
  'Hindi, Bengali, Telugu, Marathi, Tamil, Gujarati, Urdu, Kannada, Odia,',
  'Malayalam and Punjabi, and English in any Indian or other accent.',
  'Always reply in the language they just used, matching how they mix it, and',
  'switch when they switch. Your name may be said in another accent or heard',
  'transcribed in another script — "Ordi", "Ordinary", "ओर्डी", "ஆர்டி" — all of',
  'it counts as being addressed. Keep reminder titles in the language the',
  'person used.',
].join(' ');

/**
 * A speaking style layered on top of a voice. The prebuilt voices are all
 * trained on one accent, so an accent is asked for in the prompt rather than
 * chosen from a list of voices. Names are the only thing a client can send.
 */
const ACCENTS = {
  indian: [
    'ACCENT.',
    'When you speak English, speak it with a natural, warm Indian accent — the',
    'way a fluent English speaker from India sounds, with Indian rhythm and',
    'intonation. Keep it natural and never exaggerated or comical. When you',
    'speak Hindi or any other language, speak it as a native speaker would.',
  ].join(' '),
};

/** Only for clients new enough to answer these tools. */
const REMINDER_MANAGEMENT_CLAUSE = [
  'CHANGING REMINDERS. If they ask to move, reschedule, delay or change the',
  'time of a reminder that already exists, call update_reminder — never',
  'create_reminder again for the same thing. If they ask to cancel or delete',
  'one, call cancel_reminder. Only say it was moved or cancelled after the',
  'tool answers that it was. If the tool says it found no such reminder, tell',
  'them so plainly.',
].join(' ');

/**
 * What every client got before function calling existed, kept verbatim.
 *
 * Builds up to and including TestFlight build 4 cannot answer a tool call —
 * their parser drops `toolCall` frames at the `serverContent` guard — and the
 * model on this endpoint is synchronous, so an unanswered call freezes the
 * conversation for good. Handing those clients the gated prompt and the tools
 * would make the first overheard sentence (which now triggers stay_silent)
 * kill their session. They keep this until they update.
 */
const LEGACY_SYSTEM_INSTRUCTION = [
  'You are Ordi, a warm, direct, general-purpose voice assistant.',
  'You are speaking aloud in a live conversation, not writing.',
  'Keep every reply to two or three sentences.',
  'If something genuinely needs more, give the short answer first and offer to go deeper.',
  'Never use markdown, bullet points, headings, or emoji — everything you say is spoken.',
  'Do not narrate what you are about to do. Just answer.',
].join(' ');

/**
 * Pinned into the token, not declared by the client.
 *
 * The client's setup frame is discarded entirely on the constrained endpoint —
 * declaring tools there looks correct and does nothing. This is also what
 * stops a modified client from inventing its own tools.
 */
const TOOLS = [
  {
    functionDeclarations: [
      {
        name: 'stay_silent',
        description:
          'Respond with silence. Call this whenever the speech you just heard was not addressed to you — the user was talking to another person, to themselves, or it was background conversation — and for everything you hear while a recording is running. Calling this produces no spoken output, which is the desired result.',
        parameters: { type: 'object', properties: {} },
      },
      {
        name: 'create_reminder',
        description:
          'Create a reminder for the user, immediately. Call this as soon as they ask to be reminded of something or say they must not forget it. ONLY when they addressed you by name — "remind me to call the dentist" said to another person in the room is stay_silent, not this.',
        parameters: {
          type: 'object',
          properties: {
            title: {
              type: 'string',
              description:
                'The thing to be done, as a short instruction in its own right — "Call the dentist", not "remind me to call the dentist".',
            },
            at: {
              type: 'string',
              description:
                'When to fire, as a full ISO-8601 local date and time such as 2026-09-19T18:00:00. Resolve relative times like "in ten minutes" or "tomorrow at six" against the current time you were given. Omit entirely if they named no time.',
            },
          },
          required: ['title'],
        },
      },
      {
        name: 'start_recording',
        description:
          'Begin capturing a transcript of what is said from now on. Call this when the user asks you to record or take notes on a conversation, meeting, or their day. After calling it you must stay silent until it is stopped.',
        parameters: {
          type: 'object',
          properties: {
            label: {
              type: 'string',
              description:
                'A short name for this recording if the user gave one, such as "standup" or "my day".',
            },
          },
        },
      },
      {
        name: 'stop_recording',
        description:
          'Stop the running recording and return a summary of it. Call this when the user asks you to stop recording or says they are done.',
        parameters: { type: 'object', properties: {} },
      },
      {
        name: 'recall_recording',
        description:
          'Look up a past recording and return its summary so you can talk about it. Call this when the user asks what was said in an earlier conversation, meeting or recording.',
        parameters: {
          type: 'object',
          properties: {
            which: {
              type: 'string',
              description:
                'Which recording they mean — "last" for the most recent one, or the label they used for it.',
            },
          },
          required: ['which'],
        },
      },
      {
        name: 'call_contact',
        description:
          'Place a phone call. Call this when the user asks you to call, phone, dial or ring someone by name.',
        parameters: {
          type: 'object',
          properties: {
            name: {
              type: 'string',
              description: 'The name of the person to call, as the user said it.',
            },
          },
          required: ['name'],
        },
      },
    ],
  },
];

/** Added only for clients that can handle them. */
const REMINDER_TOOLS = [
  {
    functionDeclarations: [
      {
        name: 'update_reminder',
        description:
          'Change the time of a reminder that already exists — "move it to three", "push that to tomorrow", "make it 9pm instead". Use this instead of create_reminder whenever the reminder is already there. ONLY when they addressed you by name.',
        parameters: {
          type: 'object',
          properties: {
            title: {
              type: 'string',
              description:
                'Which reminder, by its words — "call the dentist". Say "last" for the one just set or discussed.',
            },
            at: {
              type: 'string',
              description:
                'The new time, as a full ISO-8601 local date and time such as 2026-09-19T15:00:00, resolved against the current time you were given.',
            },
          },
          required: ['title', 'at'],
        },
      },
      {
        name: 'cancel_reminder',
        description:
          'Delete a reminder that already exists. Call this when they ask to cancel, remove or forget one. ONLY when they addressed you by name.',
        parameters: {
          type: 'object',
          properties: {
            title: {
              type: 'string',
              description:
                'Which reminder, by its words. Say "last" for the one just set or discussed.',
            },
          },
          required: ['title'],
        },
      },
    ],
  },
];

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

// A memory digest longer than this is refused rather than truncated
// silently — truncating mid-entry can leave a dangling half-quote or a cut-off
// sentence in the prompt, which reads worse than just not having memory for
// that one session. The client is expected to keep its own digest well under
// this; it exists as a backstop against a bug or a modified client, not as
// the normal path.
const MAX_MEMORY_CHARS = 2000;

// "Remind me at six" is unresolvable without a clock, and the model has none —
// it knows roughly when it was trained and nothing else. The device sends its
// own local time so reminders land in the user's timezone rather than UTC.
// Rejected rather than trusted blindly if it doesn't parse.
function clockLine(nowIso) {
  const when = nowIso ? new Date(nowIso) : null;
  if (!when || Number.isNaN(when.getTime())) return '';
  return (
    'The current local date and time where this person is, is ' +
    `${nowIso}. Use it to resolve anything they say in relative terms — ` +
    '"in ten minutes", "tonight", "tomorrow at six".'
  );
}

function buildSystemInstruction({
  memory,
  nowIso,
  toolsEnabled,
  toolsV2 = false,
  language = '',
  accent = '',
}) {
  const parts = [toolsEnabled ? SYSTEM_INSTRUCTION : LEGACY_SYSTEM_INSTRUCTION];

  if (toolsEnabled && ACCENTS[accent]) parts.push(ACCENTS[accent]);

  if (toolsEnabled) parts.push(LANGUAGE_CLAUSE);
  if (toolsEnabled && language) {
    parts.push(
      `This person mainly speaks ${language}. Use ${language} unless they ` +
        'clearly speak something else, and for your first words in a new ' +
        'session if you have nothing else to go on.',
    );
  }
  if (toolsV2) parts.push(REMINDER_MANAGEMENT_CLAUSE);

  const clock = toolsEnabled ? clockLine(nowIso) : '';
  if (clock) parts.push(clock);

  if (memory) {
    parts.push(
      'Here is a short digest of recent past conversations with this same ' +
        'person, for context if they refer back to something — do not read ' +
        'it out or mention that you were given it, just use it naturally:',
      memory,
    );
  }

  return parts.join(' ');
}

// Handles are opaque and short — this is a defensive ceiling against a bug or
// modified client, not a real limit anyone should approach.
const MAX_RESUME_HANDLE_CHARS = 512;

async function mintToken({
  memory,
  resumeHandle,
  nowIso,
  toolsEnabled,
  toolsV2 = false,
  voice = VOICE,
  language = '',
  accent = '',
}) {
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
          // Pinned here rather than in the app so the voice cannot drift and
          // cannot be changed by a modified client.
          speechConfig: {
            voiceConfig: { prebuiltVoiceConfig: { voiceName: voice } },
          },
          systemInstruction: buildSystemInstruction({
            memory,
            nowIso,
            toolsEnabled,
            toolsV2,
            language,
            accent,
          }),
          // Pinned here for the same reason as the system instruction: on the
          // constrained endpoint the client's own setup frame is discarded, so
          // this is the only place tools can be declared — and a modified
          // client cannot add one of its own.
          // Only for clients that can answer them — see LEGACY_SYSTEM_INSTRUCTION.
          ...(toolsEnabled
            ? { tools: toolsV2 ? [...TOOLS, ...REMINDER_TOOLS] : TOOLS }
            : {}),
          // An empty object still opts into *receiving* resumption handles
          // even when there's none to resume with yet — that's what makes a
          // handle available for a later drop to actually use.
          sessionResumption: resumeHandle ? { handle: resumeHandle } : {},
          // Gives us the text of what Ordi is saying, so the app can show the
          // words as they are spoken — for noisy rooms, re-reading an
          // explanation, sound-off use, and accessibility.
          outputAudioTranscription: {},
          // The other half of the same idea, for the user's side — this is
          // what lets a conversation history record what was actually asked.
          inputAudioTranscription: {},
        },
      },
    },
  });
}

// A transcript longer than this is truncated to its last N characters before
// being sent — the tail is what matters for "what did this conversation end
// up being about", and an unbounded transcript is an unbounded bill.
const MAX_TRANSCRIPT_CHARS = 6000;

/**
 * One-shot analysis of a finished conversation: a short title, a one- or
 * two-sentence summary, and any tasks or reminders actually mentioned in it.
 *
 * Runs once per finished conversation (not once per exchange, and not on a
 * timer), and asks for all three in a single call rather than three separate
 * ones — both are the actual cost control here, more than the token cap
 * below is. `maxOutputTokens` exists as a backstop against a rambling
 * response, not as the primary lever.
 *
 * `thinkingConfig.thinkingBudget: 0` matters more than it looks: this model
 * has extended thinking on by default, and those thinking tokens are drawn
 * from the *same* `maxOutputTokens` budget as the actual answer — confirmed
 * by hand against the real API, where a 220-token cap with thinking left on
 * spent 208 tokens thinking and returned nothing but "Here is the JSON
 * requested:" before hitting the limit. A structured extraction task like
 * this one has no use for extended reasoning anyway, so turning it off both
 * fixes that truncation and removes a real, invisible cost.
 */
async function summarizeSession(transcript) {
  const clipped = transcript.length > MAX_TRANSCRIPT_CHARS
    ? transcript.slice(-MAX_TRANSCRIPT_CHARS)
    : transcript;

  const response = await ai.models.generateContent({
    model: SUMMARY_MODEL,
    contents:
      'Here is a transcript of a finished voice conversation between a ' +
      'person and their voice assistant, Ordi. Read it and respond with ' +
      'a title, a summary, and any tasks mentioned.\n\n' +
      'title: three to six words, like a short chat title — not a full ' +
      'sentence, no trailing punctuation.\n' +
      'summary: one or two plain-language sentences capturing what was ' +
      'actually discussed. Aim for the middle: not a one-word gloss that ' +
      "loses the point, not a retelling of the whole conversation — one or " +
      'two sentences is the target either way.\n' +
      'tasks: things the person needs to do, wants to be reminded of, or ' +
      'said they intend to handle — found by meaning, not by matching ' +
      'phrases like "remind me". An explicit request counts ("remind me to ' +
      'call the dentist"), but so does the same intention said in passing — ' +
      'mentioning their passport is about to expire, that they keep ' +
      'forgetting to reply to someone, or that a bill is due Friday are all ' +
      'tasks even without the word "remind" anywhere. Write each one as a ' +
      'short instruction in its own right ("Call the dentist", "Renew ' +
      'passport"), not as a quote from the transcript. Leave out anything ' +
      "that isn't really an intention to act — idle chat, things already " +
      'done, past events, and hypotheticals ("I might eventually...", ' +
      '"someday I should...") are not tasks. Empty array if there genuinely ' +
      "are none — don't invent one to have something to return.\n\n" +
      `Transcript:\n${clipped}`,
    config: {
      maxOutputTokens: 300,
      thinkingConfig: { thinkingBudget: 0 },
      responseMimeType: 'application/json',
      responseSchema: {
        type: 'OBJECT',
        properties: {
          title: { type: 'STRING' },
          summary: { type: 'STRING' },
          tasks: { type: 'ARRAY', items: { type: 'STRING' } },
        },
        required: ['title', 'summary', 'tasks'],
      },
    },
  });

  const parsed = JSON.parse(response.text);
  return {
    title: String(parsed.title ?? '').slice(0, 80),
    summary: String(parsed.summary ?? '').slice(0, 400),
    tasks: Array.isArray(parsed.tasks)
      ? parsed.tasks
          .filter((task) => typeof task === 'string' && task.trim())
          .slice(0, 10)
          .map((task) => task.trim().slice(0, 140))
      : [],
  };
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
      // /session and /diag bodies are tiny; /session-insights carries a
      // whole conversation transcript, which is what sets this ceiling.
      if (raw.length > 20_000) reject(new Error('Request body too large.'));
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

  if (req.method !== 'POST' || (req.url !== '/session' && req.url !== '/session-insights')) {
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

  if (req.url === '/session-insights') {
    const transcript = String(body.transcript ?? '').trim();
    if (!transcript) {
      return send(res, 400, { error: 'transcript is required.' });
    }
    try {
      const insights = await summarizeSession(transcript);
      return send(res, 200, insights);
    } catch (error) {
      console.error('[insights] summarize failed:', error?.message ?? error);
      return send(res, 502, {
        error: 'Could not summarise the conversation.',
        detail: error?.message ?? String(error),
      });
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

  const memory =
    typeof body.memory === 'string' ? body.memory.slice(0, MAX_MEMORY_CHARS) : '';
  const resumeHandle =
    typeof body.resumeHandle === 'string'
      ? body.resumeHandle.slice(0, MAX_RESUME_HANDLE_CHARS)
      : '';
  // The device's own local time, so "remind me at six" means six where they
  // are. Length-capped like everything else that reaches the prompt.
  const nowIso =
    typeof body.now === 'string' ? body.now.slice(0, 40) : '';

  // A client opts in by saying it can answer tool calls. The first build that
  // could (sent only its clock, no flag) is recognised by that clock too, so
  // it is not silently downgraded.
  const toolsEnabled = body.tools === true || nowIso !== '';

  // Reminder management arrived with settings, so a client sends `toolsV2`
  // only once it can answer update_reminder / cancel_reminder. Older ones keep
  // the tool set they were tested with.
  const toolsV2 = toolsEnabled && body.toolsV2 === true;

  // Both are optional and validated against fixed lists: an unknown voice
  // falls back to the default rather than failing the session.
  const voice = VOICES.includes(body.voice) ? body.voice : VOICE;
  const language = LANGUAGES.includes(body.language) ? body.language : '';
  const accent = Object.hasOwn(ACCENTS, body.accent) ? body.accent : '';

  try {
    const token = await mintToken({
      memory,
      resumeHandle,
      nowIso,
      toolsEnabled,
      toolsV2,
      voice,
      language,
      accent,
    });
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
  console.log(`  voice            ${VOICE}`);
  console.log(
    `  client secret    ${CLIENT_SECRET ? 'required' : 'NOT SET — open to anyone who can reach this'}`
  );
});

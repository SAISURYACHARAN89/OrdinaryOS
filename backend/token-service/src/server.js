import { createServer } from 'node:http';
import { GoogleGenAI } from '@google/genai';
import { PRIVACY_HTML, SUPPORT_HTML } from './pages.js';
import { accountService, handleAccountRoute, isAccountRoute, sendError } from './account-routes.js';

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
 * Tried in order when the one above is overloaded or out of quota. Seen in
 * practice: gemini-flash-latest answering "high demand" (503) for long enough
 * that no conversation got a title for days. Any of these can do the job.
 */
const SUMMARY_FALLBACKS = (process.env.SUMMARY_FALLBACKS ??
  'gemini-3-flash-preview,gemini-flash-lite-latest')
  .split(',')
  .map((m) => m.trim())
  .filter((m) => m && m !== SUMMARY_MODEL);

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

// When the session history passes CONTEXT_TRIGGER_TOKENS it is trimmed back
// to CONTEXT_TARGET_TOKENS. The instructions alone are ~3.3k tokens, so this
// keeps several minutes of real back-and-forth while capping what each turn
// re-bills.
const CONTEXT_TRIGGER_TOKENS = Number(process.env.CONTEXT_TRIGGER_TOKENS ?? 16000);
const CONTEXT_TARGET_TOKENS = Number(process.env.CONTEXT_TARGET_TOKENS ?? 10000);

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

/**
 * Whether a signed-in owner is required to open a session.
 *
 * Off while builds from before accounts are still in people's hands: those
 * present only the shared key above and keep working. A build that does send a
 * sign-in is always held to it. Turn this on once the old builds are gone;
 * they are then told to update.
 */
const AUTH_REQUIRED = process.env.AUTH_REQUIRED === 'true';

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
  'You are Ordinary, a warm, direct voice assistant. Your name is Ordinary; never call yourself Ordi.',
  '',
  'EVERY TURN, FIRST DECIDE WHETHER YOU WERE ADDRESSED. The microphone is open all day, so most of what you hear is the person talking to other people or to themselves.',
  'You were addressed only if (a) they called you by name, "Hey Ordinary" or "Ordinary" used as a name (not the everyday word, as in "an ordinary day"), or (b) you just spoke and this is plainly their reply. "Ordi" is not your name; ignore it.',
  'If you were NOT addressed, call stay_silent and say nothing: no words before or after it; stay_silent is the whole response. Overhearing a question or request ("pass me the charger", "remind me to call him" said to someone else) is not being asked. You will call stay_silent far more often than you speak.',
  '',
  'If you WERE addressed, answer aloud in one or two short sentences, offering more only if it is genuinely needed. No markdown, lists or emoji, and do not narrate what you are about to do.',
  '',
  'BEFORE CALLING ANY TOOL OTHER THAN stay_silent, CHECK: did they say "Ordinary" to you in this request, or is it plainly their reply to what you just said? If neither, call stay_silent instead, even if it sounds like a request to an assistant or says "you". Without your name, "delete all my reminders", "call Charan", "what have you recorded", "who is on your speed dial", "did you check your reminders" and "what\'s on my list" are all stay_silent; a question with "you" or "your" in it is still not addressed to you without your name. When you were addressed, call the tool in the same turn, then confirm in one short sentence; never say you will do something without calling its tool.',
  'create_reminder: when they ask to be reminded or not to forget something. Give the time in the form the tool asks for, or leave it out if none was said.',
  'start_recording / stop_recording: when they ask you to record or take notes on a conversation, meeting or their day. While a recording runs, behave exactly as usual and do not mention it unless asked.',
  'recall_recording: when they ask about a past conversation or recording; retell its summary in your own words and answer follow-ups from it.',
  'call_contact: when they ask you to call, phone or ring someone.',
  '',
  'MESSAGES STARTING WITH [ordi] COME FROM THE APP, not overheard speech: always act on them, never read the marker aloud, never mention the app, and never call a tool for them. "[ordi] remind: X" means a reminder is due: mention X in one natural sentence. "[ordi] hello" means they just picked your voice: introduce yourself as Ordinary in one friendly sentence.',
].join(' ');

/**
 * Appended for every client that gets the gated prompt. Multilingual by
 * instruction rather than by configuration: the Live model detects the spoken
 * language itself, so there is no language code to pin — this only tells it to
 * follow the person instead of defaulting to English, and that a transliterated
 * or accented "Ordi" still counts as being addressed.
 */
const LANGUAGE_CLAUSE = [
  'LANGUAGE. Default to English, including whenever you speak first (greetings, reminders): say "Hello", never "Namaste", unless another language was chosen in settings (stated below if so).',
  'English with an Indian accent or the odd Hindi word is still English. When the person speaks to you in another language, reply entirely in it, in its own script, matching how they mix languages (Hinglish, Tanglish), and return to English when they do.',
  'You understand Hindi, Bengali, Telugu, Marathi, Tamil, Gujarati, Urdu, Kannada, Odia, Malayalam, Punjabi and English in any accent. Never switch language because of an accent, a name or a place.',
  'Your name may be heard in another accent or script ("ऑर्डिनरी", "ஆர்டினரி"); that still counts. Keep reminder titles in the language the person used.',
].join(' ');

/**
 * A speaking style layered on top of a voice. The prebuilt voices are all
 * trained on one accent, so an accent is asked for in the prompt rather than
 * chosen from a list of voices. Names are the only thing a client can send.
 */
const ACCENTS = {
  indian: [
    'ACCENT.',
    'Speak with a natural, warm Indian English accent — the way a fluent',
    'English speaker from India sounds, with Indian rhythm and intonation,',
    'never exaggerated or comical. This is about how you sound, not what',
    'language you use: keep speaking English, exactly as the language rules',
    'say. Greet with "Hello", never "Namaste", and never switch to Hindi',
    'because of the accent.',
].join(' '),
};

/** Only for clients new enough to answer these tools. */
const REMINDER_MANAGEMENT_CLAUSE = [
  'CHANGING REMINDERS: to move or change the time of an existing reminder call update_reminder, never create_reminder again; to delete one call cancel_reminder. Say it was done only after the tool confirms; if it finds no such reminder, say so plainly.',
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
  'You are Ordinary, a warm, direct, general-purpose voice assistant.',
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
          'Respond with silence: call this whenever what you heard was not addressed to you. Produces no speech, which is the point.',
        parameters: { type: 'object', properties: {} },
      },
      {
        name: 'create_reminder',
        description:
          'Create a reminder now, when they ask to be reminded or not to forget something. Only if they said "Ordinary" to you in this request or are replying to you; otherwise stay_silent.',
        parameters: {
          type: 'object',
          properties: {
            title: {
              type: 'string',
              description:
                'The thing to do, as a short instruction ("Call the dentist").',
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
          'Start capturing a transcript when they ask you to record or take notes. Carry on as usual while it runs. Only if they said "Ordinary" to you in this request or are replying to you; otherwise stay_silent.',
        parameters: {
          type: 'object',
          properties: {
            label: {
              type: 'string',
              description:
                'A short name if they gave one ("standup").',
            },
          },
        },
      },
      {
        name: 'stop_recording',
        description:
          'Stop the recording when they ask. Only if they said "Ordinary" to you in this request or are replying to you; otherwise stay_silent.',
        parameters: { type: 'object', properties: {} },
      },
      {
        name: 'recall_recording',
        description:
          'Get a past recording\'s summary when they ask what was said. Only if they said "Ordinary" to you in this request or are replying to you; otherwise stay_silent.',
        parameters: {
          type: 'object',
          properties: {
            which: {
              type: 'string',
              description:
                '"last", or the name they used.',
            },
          },
          required: ['which'],
        },
      },
      {
        name: 'call_contact',
        description:
          'Call someone by name when they ask you to call or ring them. Only if they said "Ordinary" to you in this request or are replying to you; otherwise stay_silent.',
        parameters: {
          type: 'object',
          properties: {
            name: {
              type: 'string',
              description: 'The name as they said it.',
            },
          },
          required: ['name'],
        },
      },
    ],
  },
];

/**
 * How a reminder's time is passed to clients that ask for `toolsV3`: a
 * minutes-from-now count for anything relative, or a local date and a local
 * 24-hour time — never one ISO stamp. A stamp invites an offset, and the model
 * filled that in inconsistently: sometimes the right one, sometimes a "Z" on a
 * local time, and sometimes a genuine conversion to UTC. Separate fields with
 * no room for a zone make the local reading the only one there is.
 */
const TIME_FIELDS = {
  in_minutes: {
    type: 'integer',
    description:
      'Minutes from now, for relative times ("in 2 minutes"). Use instead of date/time.',
  },
  date: {
    type: 'string',
    description:
      'Local date YYYY-MM-DD; omit for today.',
  },
  time: {
    type: 'string',
    description:
      'Local 24-hour HH:MM as said ("3 pm" is 15:00). Never UTC.',
  },
};

function withTimeFields(declaration, required) {
  return {
    ...declaration,
    parameters: {
      type: 'object',
      properties: {
        title: declaration.parameters.properties.title,
        ...TIME_FIELDS,
      },
      required,
    },
  };
}

/**
 * For clients that ask for `toolsV4`: reading what is in the app and acting
 * on several things at once, plus study mode. Everything the person can see on
 * the dashboard, Ordi can now read out and change.
 */
const APP_DATA_TOOLS = [
  {
    name: 'list_reminders',
    description:
      'Read the reminders and tasks in the app. Use for any question about them; never answer from memory. Only if they said "Ordinary" to you in this request or are replying to you; otherwise stay_silent.',
    parameters: {
      type: 'object',
      properties: {
        scope: {
          type: 'string',
          enum: ['today', 'upcoming', 'all'],
          description: '"today", "upcoming" or "all" (default).',
        },
      },
    },
  },
  {
    name: 'cancel_all_reminders',
    description:
      'Delete all reminders, or all of today\'s, when asked. Only if they said "Ordinary" to you in this request or are replying to you; otherwise stay_silent.',
    parameters: {
      type: 'object',
      properties: {
        scope: {
          type: 'string',
          enum: ['today', 'all'],
          description: '"today" or "all".',
        },
      },
      required: ['scope'],
    },
  },
  {
    name: 'list_recordings',
    description:
      'List saved recordings, newest first. Only if they said "Ordinary" to you in this request or are replying to you; otherwise stay_silent.',
    parameters: { type: 'object', properties: {} },
  },
  {
    name: 'delete_recording',
    description:
      'Delete a recording, or all, when asked. Only if they said "Ordinary" to you in this request or are replying to you; otherwise stay_silent.',
    parameters: {
      type: 'object',
      properties: {
        which: {
          type: 'string',
          description: '"last", "all", or its name.',
        },
      },
      required: ['which'],
    },
  },
  {
    name: 'list_contacts',
    description:
      'List who is on speed dial. Only if they said "Ordinary" to you in this request or are replying to you; otherwise stay_silent.',
    parameters: { type: 'object', properties: {} },
  },
  {
    name: 'open_study_mode',
    description:
      'Open study mode when they mention it or want to study their notes. Then say its say_this sentence word for word, nothing more. Only if they said "Ordinary" to you in this request or are replying to you; otherwise stay_silent.',
    parameters: { type: 'object', properties: {} },
  },
];

/**
 * For clients that ask for `toolsV5` and say the person has added documents:
 * searching those PDFs. The search itself runs on the phone — only the few
 * passages it returns ever reach the model. Not declared at all for someone
 * with no documents, so they pay nothing for it.
 */
const DOCUMENT_TOOLS = [
  {
    name: 'search_documents',
    description:
      'Search the PDFs they added and get the most relevant passages with document and page. Use a few key words; try other words if nothing useful comes back. Only if they said "Ordinary" to you in this request or are replying to you; otherwise stay_silent.',
    parameters: {
      type: 'object',
      properties: {
        query: {
          type: 'string',
          description: 'Key words to look for, e.g. "buffer solution pH".',
        },
      },
      required: ['query'],
    },
  },
];

/**
 * For clients that ask for `toolsV6`: the time, read from the phone when it is
 * asked for. The instruction carries the time the session opened, and a
 * session lasts many minutes — asked the time later, the model repeated the
 * opening time as if no time had passed.
 */
const CLOCK_TOOLS = [
  {
    name: 'current_time',
    description:
      'Get the exact time and date right now from their phone. Call it every time they ask you what the time, the day or the date is. Only if they said "Ordinary" to you in this request or are replying to you; otherwise stay_silent.',
    parameters: { type: 'object', properties: {} },
  },
];

const CLOCK_CLAUSE =
  'THE TIME: the time given below is when this conversation began, and the clock keeps moving. When they ask you the time, the day or the date, call current_time and say only the part they asked for (just the time for "what time is it"), never the time below. Without your name, "what time is it", "do you have the time" and "what time does it start" are people talking to each other: stay_silent.';

const MAX_DOCUMENT_TITLES = 12;

/** Titles as plain words: nothing that could read as an instruction. */
function cleanTitles(raw) {
  if (!Array.isArray(raw)) return [];
  return raw
    .filter((t) => typeof t === 'string')
    .map((t) => t.replace(/[^\p{L}\p{N} ._()&+-]/gu, ' ').replace(/\s+/g, ' ').trim().slice(0, 60))
    .filter(Boolean)
    .slice(0, MAX_DOCUMENT_TITLES);
}

function documentsClause(titles) {
  const list = titles.length ? ` They have added: ${titles.join('; ')}.` : '';
  return (
    'THEIR DOCUMENTS: they keep PDFs in the app.' + list +
    ' search_documents is ONLY for a request where they said "Ordinary" to you, or their reply to you: people discuss documents with each other all the time. Without your name, "what does your rental agreement say about pets", "did you read the PDF I sent", "check my notes", "look it up in the document" and "that chapter is so long" are all stay_silent.' +
    ' When they did address you and the answer could be in these documents, or they mention their notes or a PDF, search, then answer in one or two sentences and name the document. If nothing is found, say so; never invent what a document says. Otherwise answer normally without searching.'
  );
}

const APP_DATA_CLAUSE = [
  'THE APP: for any question about their reminders, recordings or speed dial, call the matching list tool and answer from all of what it returns, in one or two sentences. Use the bulk tools for several at once ("delete all my reminders"). Say something was done only after the tool confirms it.',
].join(' ');

/** The tool list for one client, by what it said it can handle. */
function toolsFor({ toolsV2, toolsV3, toolsV4 = false, documents = false, liveClock = false }) {
  const base = TOOLS[0].functionDeclarations;
  const extra = [
    ...(toolsV2 ? REMINDER_TOOLS[0].functionDeclarations : []),
    ...(toolsV4 ? APP_DATA_TOOLS : []),
    ...(documents ? DOCUMENT_TOOLS : []),
    ...(liveClock ? CLOCK_TOOLS : []),
  ];
  const all = [...base, ...extra].map((d) => {
    if (!toolsV3) return d;
    if (d.name === 'create_reminder') return withTimeFields(d, ['title']);
    if (d.name === 'update_reminder') return withTimeFields(d, ['title']);
    return d;
  });
  return [{ functionDeclarations: all }];
}

/** Added only for clients that can handle them. */
const REMINDER_TOOLS = [
  {
    functionDeclarations: [
      {
        name: 'update_reminder',
        description:
          'Change the time of an existing reminder ("move it to three"). Use instead of create_reminder. Only if they said "Ordinary" to you in this request or are replying to you; otherwise stay_silent.',
        parameters: {
          type: 'object',
          properties: {
            title: {
              type: 'string',
              description:
                'Which reminder, by its words, or "last".',
            },
            at: {
              type: 'string',
              description:
                'The new local time, ISO-8601 like 2026-09-19T15:00:00.',
            },
          },
          required: ['title', 'at'],
        },
      },
      {
        name: 'cancel_reminder',
        description:
          'Delete ONE existing reminder when asked; for several or all of them use cancel_all_reminders instead. Only if they said "Ordinary" to you in this request or are replying to you; otherwise stay_silent.',
        parameters: {
          type: 'object',
          properties: {
            title: {
              type: 'string',
              description:
                'Which reminder, by its words, or "last".',
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
function clockLine(nowIso, timeFields = false) {
  const when = nowIso ? new Date(nowIso) : null;
  if (!when || Number.isNaN(when.getTime())) return '';
  if (!timeFields) {
    return (
      'The current local date and time where this person is, is ' +
      `${nowIso}. Use it to resolve anything they say in relative terms — ` +
      '"in ten minutes", "tonight", "tomorrow at six".'
    );
  }
  // Spelled out from the device's own wall-clock digits rather than handed
  // over as an ISO stamp. Given the stamp, the model sometimes converted it
  // to UTC and handed times back 5.5 hours early, so on an Indian phone a
  // reminder "in two minutes" was filed at 6:19 PM when it was 11:48 PM.
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::\d{2})?([+-]\d{2}:\d{2}|Z)?/.exec(nowIso);
  if (!m) return '';
  const [, y, mo, d, h, mi, off = ''] = m;
  const local = new Date(Date.UTC(+y, +mo - 1, +d, +h, +mi));
  const weekday = local.toLocaleDateString('en-GB', { weekday: 'long', timeZone: 'UTC' });
  const month = local.toLocaleDateString('en-GB', { month: 'long', timeZone: 'UTC' });
  const hour12 = ((+h + 11) % 12) + 1;
  return (
    `Right now it is ${weekday} ${+d} ${month} ${y}, ${hour12}:${mi} ` +
    `${+h < 12 ? 'AM' : 'PM'} local time for this person` +
    (off && off !== 'Z' ? ` (UTC${off})` : '') +
    '. Today is ' + `${y}-${mo}-${d}` + '. Every time you hear, say or pass to a tool is this ' +
    'local time. Never convert anything to UTC. For a time relative to now — ' +
    '"in two minutes", "in an hour" — give the reminder tools in_minutes, and ' +
    'do no clock arithmetic yourself.'
  );
}

function buildSystemInstruction({
  memory,
  nowIso,
  toolsEnabled,
  toolsV2 = false,
  toolsV3 = false,
  toolsV4 = false,
  documents = false,
  documentTitles = [],
  liveClock = false,
  language = '',
  accent = '',
}) {
  const parts = [toolsEnabled ? SYSTEM_INSTRUCTION : LEGACY_SYSTEM_INSTRUCTION];

  if (toolsEnabled && ACCENTS[accent]) parts.push(ACCENTS[accent]);

  if (toolsEnabled) parts.push(LANGUAGE_CLAUSE);
  if (toolsEnabled && language) {
    parts.push(
      language === 'English'
        ? 'OVERRIDING THE LANGUAGE RULES ABOVE: this person has chosen ' +
            'English in their settings. Reply only in plain English words — ' +
            'no Hindi, no Hinglish — even when they speak to you in Hindi or ' +
            'another language, which you understand and answer in English. ' +
            'The only exception is when they explicitly ask you to reply in ' +
            'another language.'
        : `This person has chosen ${language}. Use ${language} for your ` +
            'first words and whenever you are unsure, and follow them if they ' +
            'speak another language.',
    );
  }
  if (toolsV2) parts.push(REMINDER_MANAGEMENT_CLAUSE);
  if (toolsV4) parts.push(APP_DATA_CLAUSE);
  if (documents) parts.push(documentsClause(documentTitles));
  if (liveClock) parts.push(CLOCK_CLAUSE);
  // For trying another model: extra wording without a code change.
  if (toolsEnabled && process.env.INSTRUCTION_SUFFIX) parts.push(process.env.INSTRUCTION_SUFFIX);

  const clock = toolsEnabled ? clockLine(nowIso, toolsV3) : '';
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
  toolsV3 = false,
  toolsV4 = false,
  documents = false,
  documentTitles = [],
  liveClock = false,
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
            toolsV3,
            toolsV4,
            documents,
            documentTitles,
            liveClock,
            language,
            accent,
          }),
          // Pinned here for the same reason as the system instruction: on the
          // constrained endpoint the client's own setup frame is discarded, so
          // this is the only place tools can be declared — and a modified
          // client cannot add one of its own.
          // Only for clients that can answer them — see LEGACY_SYSTEM_INSTRUCTION.
          ...(toolsEnabled
            ? { tools: toolsFor({ toolsV2, toolsV3, toolsV4, documents, liveClock }) }
            : {}),
          // An empty object still opts into *receiving* resumption handles
          // even when there's none to resume with yet — that's what makes a
          // handle available for a later drop to actually use.
          sessionResumption: resumeHandle ? { handle: resumeHandle } : {},
          // Without this an audio session is capped at about fifteen minutes
          // of context and then ended. Sliding-window compression drops the
          // oldest turns instead, so an all-day session can keep going; the
          // connection itself still resets every few minutes, which the app
          // rides over with the resumption handle above.
          //
          // Measured: every turn re-bills the whole session history, and every
          // overheard sentence is a turn — twelve in a row took the billed
          // prompt from 3.3k to 4.9k tokens and it keeps climbing. Capping the
          // window bounds what one turn can cost; older turns drop off, which
          // is harmless (they are mostly overheard chatter, and long-term
          // memory comes from the app's own digest).
          contextWindowCompression: {
            triggerTokens: String(CONTEXT_TRIGGER_TOKENS),
            slidingWindow: { targetTokens: String(CONTEXT_TARGET_TOKENS) },
          },
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

  const prompt =
      'Here is a transcript of a finished voice conversation between a ' +
      'person and their voice assistant, Ordinary. Read it and respond with ' +
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
      `Transcript:\n${clipped}`;

  const response = await generateWithFallback(prompt);
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

/**
 * One summary request, moving down the model list on any failure: an
 * overload, a quota error, a config one model accepts and another rejects, or
 * an unusable answer. Only when every model has failed is the error thrown.
 */
async function generateWithFallback(prompt) {
  let lastError;
  for (const model of [SUMMARY_MODEL, ...SUMMARY_FALLBACKS]) {
    try {
      const response = await ai.models.generateContent({
        model,
        contents: prompt,
        config: summaryConfig(model),
      });
      JSON.parse(response.text); // an empty or cut-off answer counts as a miss
      return response;
    } catch (error) {
      lastError = error;
      console.warn(`[insights] ${model} failed: ${String(error?.message ?? error).slice(0, 160)}`);
    }
  }
  throw lastError;
}

function summaryConfig(model) {
  return {
      // Headroom, not a target: the answer is a few dozen tokens, but a model
      // that thinks at all draws that from the same budget, and 300 was seen
      // cutting an answer off mid-JSON.
      maxOutputTokens: 1024,
      // gemini-flash-latest takes a zero thinking budget and rejects the
      // "minimal" level; the lite alias is the other way round. Measured, not
      // documented — re-check if the aliases move.
      thinkingConfig: model === 'gemini-flash-latest' || model.startsWith('gemini-2')
        ? { thinkingBudget: 0 }
        : { thinkingLevel: 'minimal' },
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

  // Public pages linked from the store listings.
  if (req.method === 'GET' && (req.url === '/privacy' || req.url === '/support')) {
    res.writeHead(200, {
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'public, max-age=3600',
    });
    return res.end(req.url === '/privacy' ? PRIVACY_HTML : SUPPORT_HTML);
  }

  // Development telemetry. iOS device logs are not reachable from the command
  // line on current macOS, and guessing at on-device behaviour from symptoms
  // is slow and unreliable — so the app reports what it is doing here instead.
  // Remove, or gate behind a flag, before this serves real users.
  if (req.method === 'POST' && req.url === '/diag') {
    // Behind the same key as everything else. Open, anyone who found the URL
    // could fill the logs; every app build already sends the key here.
    if (CLIENT_SECRET && req.headers['x-ordi-key'] !== CLIENT_SECRET) {
      return send(res, 401, { error: 'Not authorised.' });
    }
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

  // Sign-in, the signed-in person's own record, and usage reporting.
  if (isAccountRoute(req)) {
    if (CLIENT_SECRET && req.headers['x-ordi-key'] !== CLIENT_SECRET) {
      return send(res, 401, { error: 'Not authorised.' });
    }
    return handleAccountRoute(req, res, { readJson, send });
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

  // A signed-in build is checked as its owner: must still be entitled, and for
  // a session must have credits left today. Builds from before accounts carry
  // no sign-in and are let through until AUTH_REQUIRED is switched on.
  let credits = null;
  const bearer = req.headers.authorization;
  if (bearer || AUTH_REQUIRED) {
    if (!bearer) {
      // 429 because the old builds show its message as a lasting notice.
      return send(res, 429, { code: 'update_required', error: 'Please update Ordinary to keep using it.' });
    }
    try {
      const accounts = await accountService();
      if (!accounts) {
        return send(res, 503, { code: 'accounts_unavailable', error: 'Accounts are not set up on this server.' });
      }
      const auth = await accounts.authenticate(bearer);
      if (req.url === '/session') credits = await accounts.authorizeSession(auth);
    } catch (error) {
      return sendError(res, send, error, req.url);
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

  // Signed-in sessions are counted per account, above; this per-device count
  // only ever applied to builds without accounts.
  const capped = credits ? null : claimSession(deviceId);
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
  // Reminder times as in_minutes / date / time instead of one ISO stamp.
  const toolsV3 = toolsV2 && body.toolsV3 === true;
  // Reading app data, bulk actions and study mode.
  const toolsV4 = toolsV3 && body.toolsV4 === true;
  // Searching the person's own PDFs: only for a build that can answer the
  // call, and only when they have added at least one document.
  const documents = toolsV4 && body.toolsV5 === true && body.documents === true;
  const documentTitles = documents ? cleanTitles(body.documentTitles) : [];
  // Reading the time from the phone when asked, rather than repeating the
  // time the session opened.
  const liveClock = toolsV4 && body.toolsV6 === true;

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
      toolsV3,
      toolsV4,
      documents,
      documentTitles,
      liveClock,
      voice,
      language,
      accent,
    });
    send(res, 200, {
      token: token.name,
      model: MODEL,
      expiresInSeconds: SESSION_MINUTES * 60,
      remainingSessions: remaining(deviceId),
      ...(credits ? { credits } : {}),
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
  console.log(
    `  accounts         ${process.env.MONGODB_URI ? (AUTH_REQUIRED ? 'required' : 'on (older builds still allowed)') : 'off — no database configured'}`
  );
});

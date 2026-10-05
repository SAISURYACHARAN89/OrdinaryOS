/**
 * Public pages the App Store and Play listings link to: GET /privacy and
 * GET /support. Plain HTML with inline styles, no scripts, no trackers.
 *
 * Keep the policy true to the code: if the app starts sending or keeping
 * anything new, this text has to change with it.
 */

const SUPPORT_EMAIL = process.env.SUPPORT_EMAIL ?? 'support@ordinarywearables.com';

const shell = (title, body) => `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title}</title>
<style>
  :root { color-scheme: light dark; --text:#111; --soft:#4a4a4a; --bg:#fff; --rule:#e2e2e2; }
  @media (prefers-color-scheme: dark) { :root { --text:#f2f2f2; --soft:#b5b5b5; --bg:#111; --rule:#2a2a2a; } }
  body { margin:0; background:var(--bg); color:var(--text);
         font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Inter", "Segoe UI", Roboto, sans-serif; }
  main { max-width: 680px; margin: 0 auto; padding: 40px 16px 64px; }
  h1 { font-size: 30px; line-height: 1.2; margin: 0 0 4px; }
  h2 { font-size: 19px; margin: 32px 0 8px; }
  p, li { color: var(--soft); }
  strong { color: var(--text); }
  .date { color: var(--soft); font-size: 14px; margin-bottom: 24px; }
  .box { border: 1px solid var(--rule); border-radius: 12px; padding: 4px 18px; margin: 20px 0; }
  a { color: inherit; }
</style>
</head>
<body><main>
${body}
</main></body>
</html>`;

const contactLine = SUPPORT_EMAIL
  ? `Email <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a>.`
  : 'Use the contact details on our App Store or Google Play listing.';

export const PRIVACY_HTML = shell('Ordinary OS Privacy Policy', `
<h1>Privacy Policy</h1>
<div class="date">Ordinary OS · Effective 4 October 2026</div>

<div class="box">
<p><strong>In short:</strong> Ordinary OS is an AI voice assistant for people who
own an Ordinary product. You sign in with the email you ordered with. There are
no ads and no tracking. Your reminders, recordings, transcripts and history are
kept on your phone; our servers keep only what sign-in and your daily allowance
need. We do not sell your data and we do not use it to train AI models.</p>
</div>

<h2>What stays on your phone</h2>
<ul>
  <li>Reminders, recordings (audio), transcripts and summaries</li>
  <li>Conversation history and its one-line summaries</li>
  <li>Speed Dial contacts you choose, and study notes</li>
  <li>PDFs you add under Documents, and the text Ordinary searches in them</li>
  <li>Your settings (voice, language) and the Ordinary devices you pair</li>
</ul>
<p>You can delete any of these in the app. Deleting the app deletes all of them.</p>

<h2>What leaves your phone, and why</h2>
<p><strong>Your voice, to answer you.</strong> While the app is open and listening,
microphone audio is sent over an encrypted connection straight from your phone to
Google's Gemini API, which turns speech into answers. It may include the voices of
people near you, so Ordinary is built to reply only when you say "Ordinary".</p>
<p><strong>Context for an answer.</strong> So Ordinary can help, it also shares
what a request needs: your local time, a short summary of your recent
conversations, and, when you ask about them, your reminders, recording titles or
Speed Dial names.</p>
<p><strong>Your documents.</strong> PDFs you add are read and searched on your
phone; the files are never uploaded. So that Ordinary knows what it can look in,
the names of your documents are sent when a conversation starts. When you ask
something a document can answer, the two or three short passages that match are
sent to Gemini to form the answer. We do not store any of this.</p>
<p><strong>Summaries.</strong> To title and summarise a recording or conversation,
its transcript passes through our server to Gemini. Our server returns the summary
and does not keep the transcript.</p>
<p><strong>Your account.</strong> Ordinary is for owners, so the app asks you to
sign in with a code sent to the email you ordered with. Our server checks that
email against your order and keeps a small account record:</p>
<ul>
  <li>your email address and the name on your order</li>
  <li>the phones you are signed in on (a name such as "iPhone", when it was last
      used, and a random ID for that install)</li>
  <li>how many answers Ordinary gave you each day, to apply the daily allowance —
      a count, with no record of what was asked or answered</li>
  <li>your time zone, so the allowance refills at your midnight</li>
</ul>
<p>Sign-in codes are stored scrambled and delete themselves after ten minutes.
The per-answer receipts behind the daily count are deleted after 90 days.</p>
<p><strong>Our server</strong> also gives the app short-lived access keys for Gemini.
The app reports technical events such as "connected" or "microphone started" so
we can fix problems. These contain no audio and no words you said, and are
deleted within 30 days.</p>

<h2>Google Gemini</h2>
<p>Speech and requests are processed by Google under the
<a href="https://ai.google.dev/gemini-api/terms">Gemini API Additional Terms</a>
and the <a href="https://policies.google.com/privacy">Google Privacy Policy</a>.
Ordinary uses the paid Gemini API, which Google does not use to train or improve
its models. Google may keep data for a limited time to detect abuse and meet legal
requirements, as those terms describe.</p>

<h2>No training, no selling, no ads</h2>
<p>We do not use your conversations, recordings or any other data to train AI
models. We do not sell or share your data for advertising, and the app contains
no ads or third-party analytics.</p>

<h2>Permissions</h2>
<ul>
  <li><strong>Microphone</strong> to hear you and to record when you ask</li>
  <li><strong>Speech recognition</strong> for typing by voice in the app, using
      your phone's built-in recogniser (Apple or Google, under their terms)</li>
  <li><strong>Contacts</strong> only the people you pick for Speed Dial</li>
  <li><strong>Bluetooth</strong> to connect Ordinary glasses and the Ordinary Band</li>
  <li><strong>Notifications</strong> to deliver your reminders</li>
  <li><strong>Siri</strong> for the "Talk to Ordinary" shortcut</li>
</ul>
<p>Each is optional and can be turned off in your phone's settings.</p>

<h2>Children</h2>
<p>Ordinary OS has no ads, chat with other people or tracking, and is suitable
for all ages. Accounts belong to the person who bought the product. We do not knowingly collect personal information from
children. Because speech is processed by Google to answer, we recommend a parent
or guardian supervises use by children under 13.</p>

<h2>Security</h2>
<p>All connections are encrypted (HTTPS/TLS) and access keys expire within
minutes. Sign-in is by one-time code; there is no password to steal. We keep no
conversations or recordings on our servers — only the account record described
above.</p>

<h2>Deleting your account</h2>
<p>In the app: Settings → Account → Delete account. This erases your account
record, your signed-in phones and your usage counts from our servers. Your order
with the store is a separate record; to ask about that, contact us.</p>

<h2>Changes</h2>
<p>If this policy changes, we will update this page and its effective date.</p>

<h2>Contact</h2>
<p>Questions about privacy? ${contactLine}</p>
`);

export const SUPPORT_HTML = shell('Ordinary OS Support', `
<h1>Support</h1>
<div class="date">Ordinary OS</div>

<h2>Contact us</h2>
<p>${contactLine} We usually reply within two working days.</p>

<h2>Common questions</h2>
<p><strong>Ordinary doesn't answer.</strong> Start with "Hey Ordinary" or say
"Ordinary" in your question. It stays quiet for talk that isn't meant for it.
Check that the microphone is allowed in Settings → Ordinary.</p>
<p><strong>Reminders don't alert me.</strong> Allow notifications for Ordinary in
your phone's settings.</p>
<p><strong>Changing the voice or language.</strong> Tap your profile icon on the
home screen, then choose Voice or Language.</p>
<p><strong>Pairing glasses or the Band.</strong> Tap the device card on the home
screen and keep the device close to your phone with Bluetooth on.</p>
<p><strong>I can't sign in.</strong> Use the email you gave when you ordered. The
code arrives by email within a minute; check spam. If the email says no purchase
was found, write to us with your order details.</p>
<p><strong>"Already on 2 phones".</strong> Ordinary works on two phones at a time.
Pick one to sign out on that screen, or in Settings → Account.</p>
<p><strong>I've used today's answers.</strong> The free allowance is 25 answers a
day and refills at midnight.</p>
<p><strong>Deleting my data.</strong> Swipe to delete items in the app. To erase
your account from our servers: Settings → Account → Delete account.</p>

<p><a href="/privacy">Privacy Policy</a></p>
`);

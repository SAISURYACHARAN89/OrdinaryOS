/**
 * Sign-in emails, sent through Resend's HTTP API.
 *
 * `MAIL_MODE=log` prints the message to the console instead of sending it —
 * for local development only, because it puts sign-in codes in the log. With
 * neither a key nor that mode, sending fails loudly rather than pretending.
 */

const FROM = process.env.MAIL_FROM ?? 'Ordinary Wearables <support@ordinarywearables.com>';

const shell = (body) => `<!doctype html><html><body style="margin:0;background:#f4f4f4;font-family:-apple-system,Segoe UI,Roboto,sans-serif;color:#111">
<div style="max-width:440px;margin:0 auto;padding:32px 20px">
<div style="background:#fff;border-radius:16px;padding:28px 24px">
<div style="font-weight:700;font-size:18px;margin-bottom:20px">Ordinary <span style="color:#8a8a8a;font-weight:500">OS</span></div>
${body}
</div>
<div style="color:#8a8a8a;font-size:12px;margin-top:16px;text-align:center">If you didn't ask for this, you can ignore this email.</div>
</div></body></html>`;

export function createMailer({ apiKey = process.env.RESEND_API_KEY, mode = process.env.MAIL_MODE, fetchImpl = fetch } = {}) {
  async function send({ to, subject, text, html }) {
    if (mode === 'log') {
      console.log(`[mail:log] to=${to} subject="${subject}"\n${text}`);
      return;
    }
    if (!apiKey) {
      const error = new Error('Email is not configured.');
      error.code = 'mail_unavailable';
      throw error;
    }
    const response = await fetchImpl('https://api.resend.com/emails', {
      method: 'POST',
      headers: { authorization: `Bearer ${apiKey}`, 'content-type': 'application/json' },
      body: JSON.stringify({ from: FROM, to: [to], subject, text, html }),
    });
    if (!response.ok) {
      const detail = await response.text().catch(() => '');
      const error = new Error(`Email could not be sent (${response.status}). ${detail.slice(0, 200)}`);
      error.code = 'mail_failed';
      throw error;
    }
  }

  return {
    /** The six-digit code. Valid for ten minutes. */
    sendCode: (to, code) =>
      send({
        to,
        subject: `${code} is your Ordinary code`,
        text: `Your Ordinary sign-in code is ${code}. It expires in 10 minutes.`,
        html: shell(`<div style="font-size:15px;color:#4a4a4a">Your sign-in code</div>
<div style="font-size:36px;font-weight:700;letter-spacing:6px;margin:10px 0 14px">${code}</div>
<div style="font-size:14px;color:#4a4a4a">It expires in 10 minutes.</div>`),
      }),

    /**
     * Sent instead of a code when the address has no purchase, so a mistyped
     * email is not a silent dead end — and without the app's API revealing who
     * is a customer.
     */
    sendNoPurchase: (to) =>
      send({
        to,
        subject: 'We could not find your Ordinary purchase',
        text:
          'Someone tried to sign in to the Ordinary app with this email, but we could not find ' +
          'an Ordinary purchase for it. Please use the email you gave when you ordered. ' +
          'Need help? Write to support@ordinarywearables.com.',
        html: shell(`<div style="font-size:15px;line-height:1.5;color:#4a4a4a">Someone tried to sign in to the Ordinary app with this email, but we couldn't find an Ordinary purchase for it.<br><br>Please use the email you gave when you ordered. Need help? Write to <a href="mailto:support@ordinarywearables.com" style="color:#111">support@ordinarywearables.com</a>.</div>`),
      }),
  };
}

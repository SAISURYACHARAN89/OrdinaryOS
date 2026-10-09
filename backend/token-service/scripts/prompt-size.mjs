/**
 * How many tokens are billed again on every turn: the instruction and the
 * tool declarations, measured from what the Live API itself reports for one
 * typed turn in a fresh session. Prints no secrets.
 *
 *   BASE=http://127.0.0.1:8788 node --env-file=.env scripts/prompt-size.mjs
 *
 * Reports the builds that matter: today's app, the same with documents, and
 * the same with the Band hidden.
 */
const BASE = process.env.BASE ?? 'http://127.0.0.1:8788';
const TOOLS = { tools: true, toolsV2: true, toolsV3: true, toolsV4: true, toolsV6: true };
const CASES = {
  'app today': TOOLS,
  'with documents': { ...TOOLS, toolsV5: true, documents: true, documentTitles: ['Rental Agreement 2026', 'Chemistry Chapter 4 Buffers'] },
  'Band hidden': { ...TOOLS, study: false },
  'with a memory digest': { ...TOOLS, memory: 'This morning, they asked: "what is the capital of France" — you answered: "Paris." Yesterday evening, they asked: "remind me to call mom" — you answered: "Done, I will remind you."' },
};

async function measure(extra) {
  const res = await fetch(`${BASE}/session`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...(process.env.ORDI_CLIENT_SECRET ? { 'x-ordi-key': process.env.ORDI_CLIENT_SECRET } : {}) },
    body: JSON.stringify({ deviceId: 'prompt-size', now: '2026-10-08T20:32:00+05:30', ...extra }),
  });
  const { token, model, error } = await res.json();
  if (!token) throw new Error(`no token: ${res.status} ${error}`);
  const ws = new WebSocket('wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained?access_token=' + token);
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { ws.close(); reject(new Error('timed out')); }, 30_000);
    ws.addEventListener('open', () => ws.send(JSON.stringify({ setup: { model: `models/${model}` } })));
    ws.addEventListener('close', (e) => { clearTimeout(timer); reject(new Error(`closed ${e.code} ${String(e.reason).slice(0, 80)}`)); });
    ws.addEventListener('message', async (ev) => {
      const m = JSON.parse(typeof ev.data === 'string' ? ev.data : Buffer.from(await ev.data.arrayBuffer()).toString('utf8'));
      if (m.setupComplete) ws.send(JSON.stringify({ clientContent: { turns: [{ role: 'user', parts: [{ text: 'Hey Ordinary, say hi.' }] }], turnComplete: true } }));
      if (m.toolCall) ws.send(JSON.stringify({ toolResponse: { functionResponses: m.toolCall.functionCalls.map((c) => ({ id: c.id, name: c.name, response: { result: 'ok' } })) } }));
      if (m.usageMetadata?.promptTokenCount) {
        clearTimeout(timer);
        const text = (m.usageMetadata.promptTokensDetails ?? []).find((d) => d.modality === 'TEXT')?.tokenCount;
        resolve(text ?? m.usageMetadata.promptTokenCount);
        ws.close();
      }
    });
  });
}

// BREAKDOWN=1: what each group of tools adds, to see where the size is.
const STEPS = {
  'no tools (legacy)': {},
  'wake gate + 5 tools': { tools: true },
  '+ reminder changes': { tools: true, toolsV2: true },
  '+ time fields': { tools: true, toolsV2: true, toolsV3: true },
  '+ app data': { tools: true, toolsV2: true, toolsV3: true, toolsV4: true },
  '+ clock': TOOLS,
};

for (const [name, extra] of Object.entries(process.env.BREAKDOWN ? STEPS : CASES)) {
  try {
    console.log(`${name.padEnd(24)} ${await measure(extra)} text tokens per turn`);
  } catch (error) {
    console.log(`${name.padEnd(24)} failed: ${error.message}`);
  }
}
process.exit(0);

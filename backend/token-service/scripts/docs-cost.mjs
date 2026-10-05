/**
 * What a document lookup adds to a turn, in billed tokens. Typed turns against
 * a running token service; the tool is answered with realistic passages
 * (3 x ~130 words, the app's budget). Prints usage only, no secrets.
 *
 *   BASE=http://localhost:8787 node --env-file=.env scripts/docs-cost.mjs
 */
const BASE = process.env.BASE ?? 'http://127.0.0.1:8788';
const filler = (topic) => `${topic} `.repeat(1) + 'The tenant agrees to keep the premises in good order, to pay all utility charges on time, and to give two months of written notice before leaving. '.repeat(5);
const PASSAGES = {
  results: [
    { document: 'Rental Agreement 2026', page: 3, text: 'The tenant shall pay a refundable security deposit of Rs 50,000 before moving in. ' + filler('Deposit.') },
    { document: 'Rental Agreement 2026', page: 4, text: filler('Notice period.') },
    { document: 'Chemistry Chapter 4 Buffers', page: 2, text: filler('Unrelated.') },
  ],
};
const now = new Date().toISOString();

async function run(label, turns, extra) {
  const res = await fetch(`${BASE}/session`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-ordi-key': process.env.ORDI_CLIENT_SECRET ?? '' },
    body: JSON.stringify({ deviceId: 'docs-cost', now, tools: true, toolsV2: true, toolsV3: true, toolsV4: true, ...extra }),
  });
  const { token, model } = await res.json();
  const ws = new WebSocket('wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained?access_token=' + token);
  const usage = []; let turnDone = 0; let tools = [];
  await new Promise((resolve, reject) => {
    ws.addEventListener('open', () => ws.send(JSON.stringify({ setup: { model: `models/${model}` } })));
    ws.addEventListener('message', async (ev) => {
      const raw = typeof ev.data === 'string' ? ev.data : Buffer.from(await ev.data.arrayBuffer()).toString('utf8');
      const m = JSON.parse(raw);
      if (m.setupComplete) resolve();
      if (m.usageMetadata) usage.push(m.usageMetadata);
      if (m.toolCall) {
        const calls = m.toolCall.functionCalls ?? [];
        tools.push(...calls.map((c) => c.name));
        ws.send(JSON.stringify({ toolResponse: { functionResponses: calls.map((c) => ({ id: c.id, name: c.name, response: c.name === 'search_documents' ? PASSAGES : { result: 'ok' } })) } }));
      }
      if (m.serverContent?.turnComplete) turnDone++;
    });
    ws.addEventListener('error', () => reject(new Error('socket error')));
  });
  const perTurn = [];
  for (const text of turns) {
    const before = usage.length; const want = turnDone + 1;
    ws.send(JSON.stringify({ clientContent: { turns: [{ role: 'user', parts: [{ text }] }], turnComplete: true } }));
    const start = Date.now();
    while (turnDone < want && Date.now() - start < 20000) await new Promise((r) => setTimeout(r, 100));
    await new Promise((r) => setTimeout(r, 500));
    const slice = usage.slice(before);
    const sum = (f) => slice.reduce((a, u) => a + (u[f] ?? 0), 0);
    perTurn.push({ steps: slice.length, prompt: sum('promptTokenCount'), out: sum('responseTokenCount'), toolPrompt: sum('toolUsePromptTokenCount') });
  }
  ws.close();
  console.log(label.padEnd(34), 'tools=[' + tools.join(',') + ']');
  perTurn.forEach((t, i) => console.log(`   turn ${i + 1}: billed input ${t.prompt} tokens over ${t.steps} model step(s), output ${t.out}`));
  return perTurn;
}

const DOCS = { toolsV5: true, documents: true, documentTitles: ['Rental Agreement 2026', 'Chemistry Chapter 4 Buffers'] };
await run('no documents: plain question', ['Hey Ordinary, what is the capital of Japan?', 'And what about France?']);
await run('has documents: plain question', ['Hey Ordinary, what is the capital of Japan?', 'And what about France?'], DOCS);
await run('has documents: document question', ['Hey Ordinary, how much is the security deposit in my rental agreement?', 'And what is the capital of France?'], DOCS);
process.exit(0);

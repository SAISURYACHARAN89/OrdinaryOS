# Ordi token service

Mints short-lived Gemini Live tokens so the app can connect to Google directly.

**Audio never passes through this service.** An audio relay would add a network
hop to every chunk in both directions, and latency is the entire reason
speech-to-speech was chosen over a chained pipeline. This exists for three
things the app cannot be trusted with:

1. **Key custody** — the real API key never leaves this process.
2. **Usage metering** — a device out of allowance simply gets no token.
3. **Prompt custody** — the system instruction and the two-to-three-sentence
   reply limit are pinned into the token's `liveConnectConstraints`, so a
   modified client cannot strip them. Reply length is a ~5x swing on the
   monthly bill, so this is a cost control, not a style preference.

## Running it

```bash
cp .env.example .env     # then paste your key into .env
npm install
npm start
```

Listens on `0.0.0.0:8787` so a phone on the same Wi-Fi can reach it.

## API

`GET /health` -> `{ ok: true, model }`

`POST /session` with `{ "deviceId": "..." }` ->
`{ token, model, expiresInSeconds, remainingSessions }`, or `429` when the
device is out of allowance for the day.

## Known limits

- Usage is held **in memory** and resets when the process restarts. That is
  deliberate for v1 — there are no accounts yet and the cap was accepted as
  bypassable. It is the first thing to replace when this is deployed anywhere
  real.
- `deviceId` is self-reported by the client, so the cap is per-install rather
  than per-person.

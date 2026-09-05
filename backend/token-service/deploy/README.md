# Deploying the token service to EC2

## What you need first

1. **An Ubuntu instance** — t4g.nano or t3.micro is plenty. This service is
   idle almost all the time and holds no state.
2. **A security group** allowing inbound **443**, and **80** (Let's Encrypt
   needs it to issue the certificate). Do *not* open 8787 to the world — Caddy
   reaches it over localhost.
3. **A domain name pointed at the instance IP.** Not optional:
   **iOS refuses cleartext HTTP to a public address**, so the app cannot reach a
   bare EC2 IP no matter how the security group is set. Any cheap domain, or a
   subdomain of one you already own, will do.

## Deploying

    ./deploy.sh ubuntu@YOUR_IP ~/.ssh/your-key.pem ordi.yourdomain.com

Installs Node 22, creates an unprivileged `ordi` user, copies the source,
installs Caddy, obtains a certificate, and starts everything under systemd.
Re-run it any time to redeploy — it is idempotent.

**Your API key never travels.** `.env` is excluded from the copy deliberately.
Create it once, on the instance:

    sudo -u ordi tee /opt/ordi-token/.env >/dev/null <<'ENVFILE'
    GEMINI_API_KEY=your-key-here
    ORDI_CLIENT_SECRET=paste-a-random-hex-string
    SESSIONS_PER_DAY=0
    ENVFILE

    sudo systemctl restart ordi-token

Generate the secret with `openssl rand -hex 32` and keep a copy — the app is
built with the same value.

## Pointing the app at it

    flutter build ios --release \
      --dart-define=ORDI_BACKEND=https://ordi.yourdomain.com \
      --dart-define=ORDI_CLIENT_SECRET=the-same-secret

Once the backend is on HTTPS, **remove `NSAppTransportSecurity` from
`ios/Runner/Info.plist`**. That exception exists only for talking to a laptop
on the local network; shipping it weakens the app for nothing.

## Checking on it

    curl https://ordi.yourdomain.com/health
    ssh -i key.pem ubuntu@IP 'sudo journalctl -u ordi-token -f'

## Known limits, carried over from local

- Usage counts live **in memory** and reset when the process restarts, so the
  daily cap resets on every deploy. Fine while there are no real users; replace
  it with a small database before there are.
- `ORDI_CLIENT_SECRET` ships inside the app and can be extracted. It stops a
  leaked URL becoming free Gemini credit for strangers. It is not user
  authentication.

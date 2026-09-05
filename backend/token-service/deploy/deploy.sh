#!/usr/bin/env bash
#
# Push the token service to an EC2 instance and (re)start it.
#
#   ./deploy.sh ubuntu@1.2.3.4 ~/.ssh/ordi.pem
#
# Idempotent: safe to run repeatedly, which is the point — this is how you
# redeploy after a code change, not just the first-time setup.
set -euo pipefail

HOST="${1:?usage: ./deploy.sh user@host /path/to/key.pem [domain]}"
KEY="${2:?usage: ./deploy.sh user@host /path/to/key.pem [domain]}"
DOMAIN="${3:-}"

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=accept-new "$HOST")

echo "==> preparing the remote"
"${SSH[@]}" bash -s <<'REMOTE'
set -euo pipefail
if ! command -v node >/dev/null || [ "$(node -v | cut -c2-3)" -lt 20 ]; then
  echo "installing Node 22"
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
  sudo apt-get install -y nodejs
fi
id ordi >/dev/null 2>&1 || sudo useradd --system --home /opt/ordi-token --shell /usr/sbin/nologin ordi
sudo mkdir -p /opt/ordi-token
sudo chown -R "$USER":"$USER" /opt/ordi-token
REMOTE

echo "==> copying source (no node_modules, no .env — secrets never travel)"
rsync -az --delete -e "ssh -i $KEY -o StrictHostKeyChecking=accept-new" \
  --exclude node_modules --exclude .env --exclude deploy \
  "$HERE"/ "$HOST":/opt/ordi-token/

echo "==> installing dependencies and the service"
"${SSH[@]}" bash -s <<'REMOTE'
set -euo pipefail
cd /opt/ordi-token
npm ci --omit=dev 2>/dev/null || npm install --omit=dev

if [ ! -f /opt/ordi-token/.env ]; then
  echo
  echo "!!  /opt/ordi-token/.env does not exist yet."
  echo "!!  Create it on the instance with your key and a client secret:"
  echo "!!"
  echo "!!    sudo -u ordi tee /opt/ordi-token/.env >/dev/null <<EOF"
  echo "!!    GEMINI_API_KEY=your-key"
  echo "!!    ORDI_CLIENT_SECRET=\$(openssl rand -hex 32)"
  echo "!!    EOF"
  echo
fi

sudo chown -R ordi:ordi /opt/ordi-token
sudo cp /opt/ordi-token/deploy/ordi-token.service /etc/systemd/system/ 2>/dev/null || true
sudo systemctl daemon-reload
sudo systemctl enable ordi-token
sudo systemctl restart ordi-token
sleep 2
sudo systemctl --no-pager --lines=15 status ordi-token || true
REMOTE

# the unit file lives under deploy/, which rsync excludes — send it directly
scp -i "$KEY" -o StrictHostKeyChecking=accept-new \
  "$HERE/deploy/ordi-token.service" "$HOST":/tmp/ordi-token.service
"${SSH[@]}" 'sudo mv /tmp/ordi-token.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl restart ordi-token'

if [ -n "$DOMAIN" ]; then
  echo "==> setting up HTTPS for $DOMAIN"
  "${SSH[@]}" bash -s <<REMOTE
set -euo pipefail
if ! command -v caddy >/dev/null; then
  sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
    | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
    | sudo tee /etc/apt/sources.list.d/caddy-stable.list
  sudo apt-get update && sudo apt-get install -y caddy
fi
sudo tee /etc/caddy/Caddyfile >/dev/null <<CADDY
$DOMAIN {
	reverse_proxy 127.0.0.1:8787
	@blocked not path /session /health
	respond @blocked 404
	encode gzip
}
CADDY
sudo systemctl reload caddy || sudo systemctl restart caddy
echo "HTTPS should now be live at https://$DOMAIN"
REMOTE
fi

echo
echo "==> done"
[ -n "$DOMAIN" ] && echo "    https://$DOMAIN/health" || echo "    http://\${HOST#*@}:8787/health  (HTTP only — iOS will refuse this)"

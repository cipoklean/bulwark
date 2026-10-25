#!/usr/bin/env bash
# Makes the Bulwark keeper start by itself on boot and restart if it crashes.
# Usage: bash keeper/install-service.sh        Remove: bash keeper/install-service.sh remove
# Needs keeper/.env (run keeper/start.sh once first). Logs: journalctl -u bulwark-keeper -f
set -euo pipefail
cd "$(dirname "$0")"
DIR=$(pwd)
UNIT=/etc/systemd/system/bulwark-keeper.service

if [ "${1:-}" = "remove" ]; then
  sudo systemctl disable --now bulwark-keeper 2>/dev/null || true
  sudo rm -f "$UNIT" && sudo systemctl daemon-reload && echo "Service removed."
  exit 0
fi

[ -f .env ] || { echo "No keeper/.env yet. Run: bash keeper/start.sh  (once), then this again."; exit 1; }
NODE=$(command -v node) || { echo "Node.js not found in PATH."; exit 1; }
NODE=$(readlink -f "$NODE")  # fnm/nvm shims live in temp dirs; use the real binary
[ -d node_modules ] || npm install --silent
TSX="$DIR/node_modules/.bin/tsx"
[ -x "$TSX" ] || npm install --silent tsx

# Stop the old nohup keeper so two never run at once.
if [ -f keeper.pid ]; then kill "$(cat keeper.pid)" 2>/dev/null || true; rm -f keeper.pid; fi
pkill -f "src/index.ts" 2>/dev/null || true

sudo tee "$UNIT" >/dev/null <<EOF
[Unit]
Description=Bulwark keeper (Mezo MUSD loan rescues)
After=network-online.target
Wants=network-online.target

[Service]
User=$(id -un)
WorkingDirectory=$DIR
EnvironmentFile=$DIR/.env
Environment=PATH=$(dirname "$NODE"):/usr/local/bin:/usr/bin:/bin
ExecStart=$TSX src/index.ts
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now bulwark-keeper
sleep 8
systemctl --no-pager --lines=5 status bulwark-keeper || true
echo
echo "Keeper is a service now. It starts on every boot."
echo "Watch it: journalctl -u bulwark-keeper -f    Restart: sudo systemctl restart bulwark-keeper"

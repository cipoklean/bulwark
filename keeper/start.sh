#!/usr/bin/env bash
# Starts the Bulwark keeper in the background. Usage: bash keeper/start.sh [FACTORY]
# Logs: keeper/keeper.log   Stop: bash keeper/start.sh stop
set -euo pipefail
cd "$(dirname "$0")"
if [ "${1:-}" = "stop" ]; then [ -f keeper.pid ] && kill "$(cat keeper.pid)" && rm keeper.pid && echo "Keeper stopped."; exit 0; fi
command -v node >/dev/null || { echo "Node.js 18+ is needed: https://nodejs.org (or: curl -fsSL https://fnm.vercel.app/install | bash; fnm install 22)"; exit 1; }
[ -d node_modules ] || npm install --silent
if [ ! -f .env ]; then
  read -rsp "Keeper wallet private key: " PK; echo
  F=${1:-0x68Eb65479E3396548113F307d11C8Bd66e59025a}
  printf 'RPC_URL=https://rpc.test.mezo.org\nPRIVATE_KEY=%s\nFACTORY=%s\nPOLL_SECONDS=30\nWARN_MARGIN_PCT=10\nTELEGRAM_BOT_TOKEN=\nTELEGRAM_CHAT_ID=\n' "$PK" "$F" > .env
  chmod 600 .env
fi
[ -f keeper.pid ] && kill -0 "$(cat keeper.pid)" 2>/dev/null && { echo "Keeper already running (pid $(cat keeper.pid))."; exit 0; }
nohup npx tsx src/index.ts >> keeper.log 2>&1 &
echo $! > keeper.pid
sleep 8; tail -3 keeper.log
echo "Keeper running (pid $(cat keeper.pid)). Watch it: tail -f keeper/keeper.log"

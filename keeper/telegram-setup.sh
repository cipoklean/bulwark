#!/usr/bin/env bash
# Links Telegram alerts: asks for the BotFather token, finds your chat, sends a test, restarts the keeper.
# Before running: create the bot with @BotFather, then send your new bot any message (e.g. "hi").
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || { echo "Run bash keeper/start.sh first."; exit 1; }
read -rsp "Telegram bot token: " TOKEN; echo
CHAT=$(curl -s "https://api.telegram.org/bot$TOKEN/getUpdates" | python3 -c 'import sys,json
d=json.load(sys.stdin)
if not d.get("ok"): sys.exit("Token rejected by Telegram.")
m=[u.get("message") or u.get("my_chat_member") for u in d["result"]]
m=[x for x in m if x]
if not m: sys.exit("No messages yet. Send your bot \"hi\" in Telegram, then run this again.")
print(m[-1]["chat"]["id"])')
sed -i "s|^TELEGRAM_BOT_TOKEN=.*|TELEGRAM_BOT_TOKEN=$TOKEN|; s|^TELEGRAM_CHAT_ID=.*|TELEGRAM_CHAT_ID=$CHAT|" .env
chmod 600 .env
curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d chat_id="$CHAT" \
  --data-urlencode text="🛡️ Bulwark is watching your vault. You'll hear from me here if your loan gets close to its rescue line, and after every rescue." >/dev/null
bash start.sh stop >/dev/null 2>&1 || true
bash start.sh | tail -1
echo "Telegram linked (chat $CHAT). Check your phone for the test message."

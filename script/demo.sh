#!/usr/bin/env bash
# Live demo: raises your vault's trigger above its current health so the keeper rescues it for real.
# Usage:  bash script/demo.sh            (trigger 175%, target 185% by default)
#         bash script/demo.sh 180 190    (custom trigger and target)
#         bash script/demo.sh reset      (puts the normal rule back: 160% -> 175%)
# Needs: cast (Foundry) and the keeper running (bash keeper/start.sh).
set -euo pipefail
export PATH="$PATH:$HOME/.foundry/bin:${FOUNDRY_DIR:-$HOME/.foundry}/bin"
command -v cast >/dev/null || { echo "Installing Foundry (one time)..."; curl -sL https://foundry.paradigm.xyz | bash >/dev/null; ~/.foundry/bin/foundryup >/dev/null; }
cd "$(dirname "$0")/.."
RPC=${RPC_URL:-https://rpc.test.mezo.org}
FACTORY=${FACTORY:-0x68Eb65479E3396548113F307d11C8Bd66e59025a}
TM=0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0
PF=0x86bCF0841622a5dAC14A313a15f96A95421b9366
FEE_BPS=${FEE_BPS:-50}

if [ -z "${PRIVATE_KEY:-}" ] && [ -f keeper/.env ]; then PRIVATE_KEY=$(grep '^PRIVATE_KEY=' keeper/.env | cut -d= -f2-); fi
if [ -z "${PRIVATE_KEY:-}" ]; then read -rsp "Vault owner private key: " PRIVATE_KEY; echo; fi

ME=$(cast wallet address "$PRIVATE_KEY")
VAULT=$(cast call $FACTORY "vaultOf(address)(address)" $ME --rpc-url $RPC)
icr() { local p; p=$(cast call $PF "fetchPrice()(uint256)" --rpc-url $RPC | cut -d' ' -f1)
  cast call $TM "getCurrentICR(address,uint256)(uint256)" $VAULT $p --rpc-url $RPC | cut -d' ' -f1 | awk '{printf "%.1f", $1/1e16}'; }
# Works with both old and new cast JSON output (plain object/list, or a {"data": ...} envelope).
PYTX='import sys,json
d=json.load(sys.stdin)
d=d.get("data",d) if isinstance(d,dict) and "schema_version" in d else d
if isinstance(d,list): d=d[-1] if d else {}
print((d or {}).get("transactionHash",""))'
pct() { cast to-wei "$(python3 -c "print($1/100)")"; }
setrule() { cast send $VAULT "setRule(uint256,uint256,uint256)" "$(pct $1)" "$(pct $2)" $FEE_BPS \
  --rpc-url $RPC --private-key "$PRIVATE_KEY" --legacy --gas-limit 300000 --json | python3 -c "$PYTX"; }

if [ "${1:-}" = "reset" ]; then
  echo "Restoring the normal rule (160% -> 175%)..."; echo "tx $(setrule 160 175)"; echo "Done. Health is $(icr)%."; exit 0; fi

TRIGGER=${1:-175}; TARGET=${2:-185}
NOW=$(icr)
echo "Vault $VAULT"
echo "Health right now: ${NOW}%"
python3 -c "import sys; sys.exit(0 if $TRIGGER > $NOW else 1)" || { echo "Trigger ${TRIGGER}% is not above ${NOW}%. Try: bash script/demo.sh $(python3 -c "print(int($NOW)+5)") $(python3 -c "print(int($NOW)+15)")"; exit 1; }

echo; echo "Step 1. Setting the rule: rescue below ${TRIGGER}%, bring it back to ${TARGET}%."
echo "        tx $(setrule $TRIGGER $TARGET)"
START=$(cast block-number --rpc-url $RPC)
echo; echo "Step 2. The vault is now 'in danger' by its own rule. Waiting for the keeper..."
for i in $(seq 1 40); do
  sleep 6
  LOG=$(cast logs --from-block $START --address $VAULT "Rescued(address,uint256,uint256,uint256,uint256,uint256)" --rpc-url $RPC --json 2>/dev/null || echo "[]")
  TX=$(echo "$LOG" | python3 -c "$PYTX" 2>/dev/null || true)
  if [ -n "$TX" ]; then
    echo; echo "Step 3. RESCUED by the keeper."
    echo "        tx $TX"
    echo "        Health: ${NOW}% -> $(icr)%"
    echo "        Explorer: https://explorer.test.mezo.org/tx/$TX"
    echo; echo "Check Telegram for the alert. When you're done filming: bash script/demo.sh reset"
    exit 0
  fi
  printf "."
done
echo; echo "No rescue after 4 minutes. Is the keeper running? tail -20 keeper/keeper.log"
exit 1

#!/usr/bin/env bash
# Deploys BulwarkFactory, creates your vault, opens a loan, and sets the rescue rule.
# Usage: bash script/deploy.sh   (reads PRIVATE_KEY from .env or asks)
# Optional env: COLL (BTC, default 0.045), BORROW (MUSD, default 2300), RESERVE (MUSD kept, default 450),
#               TRIGGER (%, default 160), TARGET (%, default 175), FEE_BPS (default 50), FACTORY (reuse one)
set -euo pipefail
RPC=${RPC:-https://rpc.test.mezo.org}
BO=0xCdF7028ceAB81fA0C6971208e83fa7872994beE5
TM=0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0
MUSD=0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503
PF=0x86bCF0841622a5dAC14A313a15f96A95421b9366
HH=0x4e4cBA3779d56386ED43631b4dCD6d8EacEcBCF6
ST=0x722E4D24FD6Ff8b0AC679450F3D91294607268fA
COLL=${COLL:-0.045}; BORROW=${BORROW:-2300}; RESERVE=${RESERVE:-450}
TRIGGER=${TRIGGER:-160}; TARGET=${TARGET:-175}; FEE_BPS=${FEE_BPS:-50}

export PATH="$PATH:$HOME/.foundry/bin:${FOUNDRY_DIR:-$HOME/.foundry}/bin"
command -v forge >/dev/null || { curl -sL https://foundry.paradigm.xyz | bash; ~/.foundry/bin/foundryup; export PATH="$PATH:$HOME/.foundry/bin"; }
cd "$(dirname "$0")/.."
[ -d lib/forge-std ] || forge install foundry-rs/forge-std --no-git >/dev/null
if [ -z "${PRIVATE_KEY:-}" ] && [ -f .env ]; then source .env; fi
if [ -z "${PRIVATE_KEY:-}" ]; then read -rsp "Test wallet private key: " PRIVATE_KEY; echo; fi
ME=$(cast wallet address "$PRIVATE_KEY")
echo "Wallet $ME has $(cast balance $ME --ether --rpc-url $RPC) BTC"

send() { local out; out=$(cast send "$@" --rpc-url $RPC --private-key $PRIVATE_KEY --legacy --gas-limit 3000000 2>&1) || { echo "$out"; exit 1; }
  echo "$out" | grep -q "status *1" || { echo "Transaction failed:"; echo "$out"; exit 1; }
  echo "  tx $(echo "$out" | awk '/^transactionHash/{print $2}')"; }
hints() { local nicr h; nicr=$(cast call $HH "computeNominalCR(uint256,uint256)(uint256)" $1 $2 --rpc-url $RPC | cut -d' ' -f1)
  h=$(cast call $HH "getApproxHint(uint256,uint256,uint256)(address,uint256,uint256)" $nicr 50 42 --rpc-url $RPC | head -1)
  cast call $ST "findInsertPosition(uint256,address,address)(address,address)" $nicr $h $h --rpc-url $RPC | tr '\n' ' '; }
icr() { local p; p=$(cast call $PF "fetchPrice()(uint256)" --rpc-url $RPC | cut -d' ' -f1)
  cast call $TM "getCurrentICR(address,uint256)(uint256)" $1 $p --rpc-url $RPC | cut -d' ' -f1 | awk '{printf "%.1f%%", $1/1e16}'; }

if [ -z "${FACTORY:-}" ]; then
  FACTORY=$(forge create src/BulwarkFactory.sol:BulwarkFactory --rpc-url $RPC --private-key $PRIVATE_KEY --broadcast --legacy \
    --constructor-args $BO $TM $PF $MUSD | awk '/Deployed to:/{print $3}')
  echo "BulwarkFactory: $FACTORY"
fi
VAULT=$(cast call $FACTORY "vaultOf(address)(address)" $ME --rpc-url $RPC)
if [ "$VAULT" = "0x0000000000000000000000000000000000000000" ]; then
  send $FACTORY "createVault()"
  VAULT=$(cast call $FACTORY "vaultOf(address)(address)" $ME --rpc-url $RPC)
fi
echo "Your vault: $VAULT"

COLL_WEI=$(cast to-wei $COLL); BORROW_WEI=$(cast to-wei $BORROW); RESERVE_WEI=$(cast to-wei $RESERVE)
FEE=$(cast call $BO "getBorrowingFee(uint256)(uint256)" $BORROW_WEI --rpc-url $RPC | cut -d' ' -f1)
DEBT=$(python3 -c "print($BORROW_WEI + 200*10**18 + $FEE)")
send $VAULT "openLoan(uint256,uint256,address,address)" $BORROW_WEI $RESERVE_WEI $(hints $COLL_WEI $DEBT) --value ${COLL}ether
send $VAULT "setRule(uint256,uint256,uint256)" $(cast to-wei $(python3 -c "print($TRIGGER/100)")) $(cast to-wei $(python3 -c "print($TARGET/100)")) $FEE_BPS
echo "Loan open at $(icr $VAULT). Reserve $(cast call $VAULT 'reserve()(uint256)' --rpc-url $RPC | cut -d' ' -f1 | awk '{print $1/1e18}') MUSD. Rule: rescue below ${TRIGGER}%, back to ${TARGET}%, fee ${FEE_BPS} bps."
echo "FACTORY=$FACTORY"
echo "VAULT=$VAULT"
echo "Explorer: https://explorer.test.mezo.org/address/$VAULT"

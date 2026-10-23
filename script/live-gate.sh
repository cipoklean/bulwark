#!/usr/bin/env bash
# Bulwark live gate test on Mezo testnet.
# Deploys a tiny vault, opens a 2,300 MUSD loan with 0.045 BTC, repays 400 MUSD, prints the ratio.
set -euo pipefail
RPC=${RPC:-https://rpc.test.mezo.org}
BO=0xCdF7028ceAB81fA0C6971208e83fa7872994beE5
TM=0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0
MUSD=0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503
PF=0x86bCF0841622a5dAC14A313a15f96A95421b9366
HH=0x4e4cBA3779d56386ED43631b4dCD6d8EacEcBCF6
ST=0x722E4D24FD6Ff8b0AC679450F3D91294607268fA
COLL=${COLL:-0.045ether}; BORROW=${BORROW:-2300ether}; REPAY=${REPAY:-400ether}

command -v forge >/dev/null || { curl -sL https://foundry.paradigm.xyz | bash; ~/.foundry/bin/foundryup; }
export PATH="$PATH:$HOME/.foundry/bin"

if [ -z "${PRIVATE_KEY:-}" ]; then [ -f .env ] && source .env; fi
if [ -z "${PRIVATE_KEY:-}" ]; then read -rsp "Test wallet private key: " PRIVATE_KEY; echo; fi
ME=$(cast wallet address "$PRIVATE_KEY")
echo "Wallet $ME has $(cast balance $ME --ether --rpc-url $RPC) BTC"

mkdir -p bulwark-gate/src && cd bulwark-gate
[ -f foundry.toml ] || printf '[profile.default]\nsrc="src"\nout="out"\n' > foundry.toml
cat > src/GateVault.sol <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
interface IBO {
    function openTrove(uint256, address, address) external payable;
    function repayMUSD(uint256, address, address) external;
}
contract GateVault {
    IBO public immutable bo; address public immutable owner;
    constructor(address _bo) { bo = IBO(_bo); owner = msg.sender; }
    function open(uint256 debt, address up, address low) external payable { require(msg.sender == owner, "owner"); bo.openTrove{value: msg.value}(debt, up, low); }
    function repayFromReserve(uint256 amt, address up, address low) external { bo.repayMUSD(amt, up, low); }
    receive() external payable {}
}
SOL

send() { local out; out=$(cast send "$@" --rpc-url $RPC --private-key $PRIVATE_KEY --legacy --gas-limit 3000000 2>&1) || { echo "$out"; exit 1; }
  echo "$out" | grep -q "status *1" || { echo "Transaction failed:"; echo "$out"; exit 1; }
  echo "  tx $(echo "$out" | awk '/^transactionHash/{print $2}')"; }
# Position hints: tell Mezo where the loan sits in its sorted list, so the call stays cheap.
hints() { local nicr h; nicr=$(cast call $HH "computeNominalCR(uint256,uint256)(uint256)" $1 $2 --rpc-url $RPC | cut -d' ' -f1)
  h=$(cast call $HH "getApproxHint(uint256,uint256,uint256)(address,uint256,uint256)" $nicr 50 42 --rpc-url $RPC | head -1)
  cast call $ST "findInsertPosition(uint256,address,address)(address,address)" $nicr $h $h --rpc-url $RPC | tr '\n' ' '; }
icr() { local p; p=$(cast call $PF "fetchPrice()(uint256)" --rpc-url $RPC | cut -d' ' -f1)
  cast call $TM "getCurrentICR(address,uint256)(uint256)" $1 $p --rpc-url $RPC | cut -d' ' -f1 | awk '{printf "%.1f%%", $1/1e16}'; }

V=$(forge create src/GateVault.sol:GateVault --rpc-url $RPC --private-key $PRIVATE_KEY --broadcast --legacy --constructor-args $BO | awk '/Deployed to:/{print $3}')
echo "Gate vault deployed: $V"
COLL_WEI=$(cast to-wei ${COLL%ether}); BORROW_WEI=$(cast to-wei ${BORROW%ether}); REPAY_WEI=$(cast to-wei ${REPAY%ether})
FEE=$(cast call $BO "getBorrowingFee(uint256)(uint256)" $BORROW_WEI --rpc-url $RPC | cut -d' ' -f1)
DEBT=$(python3 -c "print($BORROW_WEI + 200*10**18 + $FEE)")
send $V "open(uint256,address,address)" $BORROW_WEI $(hints $COLL_WEI $DEBT) --value $COLL
echo "Gate 1: trove status $(cast call $TM 'getTroveStatus(address)(uint256)' $V --rpc-url $RPC) (1 = active), ratio $(icr $V), vault MUSD $(cast call $MUSD 'balanceOf(address)(uint256)' $V --rpc-url $RPC | cut -d' ' -f1 | awk '{print $1/1e18}')"
read -r C P _ <<<"$(cast call $TM 'getEntireDebtAndColl(address)(uint256,uint256,uint256,uint256,uint256,uint256)' $V --rpc-url $RPC | cut -d' ' -f1 | tr '\n' ' ')"
send $V "repayFromReserve(uint256,address,address)" $REPAY_WEI $(hints $C $(python3 -c "print($P - $REPAY_WEI)"))
echo "Gate 2: ratio after repaying ${REPAY%ether} MUSD: $(icr $V)"
echo "Explorer: https://explorer.test.mezo.org/address/$V"

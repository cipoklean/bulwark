/**
 * Bulwark keeper: watches every Bulwark vault and rescues any loan that falls below
 * its owner's trigger. Anyone can run it; the first keeper to rescue earns the fee.
 *
 * Env: RPC_URL, PRIVATE_KEY, FACTORY, POLL_SECONDS (default 30),
 *      TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID (optional alerts), WARN_MARGIN_PCT (default 10)
 */
import "dotenv/config";
import {
  createPublicClient, createWalletClient, defineChain, formatUnits, http, parseAbi, type Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const mezoTestnet = defineChain({
  id: 31611,
  name: "Mezo Testnet",
  nativeCurrency: { name: "Bitcoin", symbol: "BTC", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.test.mezo.org"] } },
  blockExplorers: { default: { name: "Mezo Explorer", url: "https://explorer.test.mezo.org" } },
});

const MEZO = {
  hintHelpers: "0x4e4cBA3779d56386ED43631b4dCD6d8EacEcBCF6" as Address,
  sortedTroves: "0x722E4D24FD6Ff8b0AC679450F3D91294607268fA" as Address,
};

const factoryAbi = parseAbi(["function allVaults() view returns (address[])"]);
const vaultAbi = parseAbi([
  "function previewRescue() returns (bool canRescue, uint256 icr, uint256 repay, uint256 fee)",
  "function rescue(address upperHint, address lowerHint) returns (uint256 repaid, uint256 fee)",
  "function loan() view returns (uint256 coll, uint256 debt)",
  "function rule() view returns (uint64 triggerICR, uint64 targetICR, uint16 feeBps)",
  "function owner() view returns (address)",
  "event Rescued(address indexed keeper, uint256 icrBefore, uint256 icrAfter, uint256 repaid, uint256 fee, uint256 price)",
]);
const hintAbi = parseAbi([
  "function computeNominalCR(uint256 coll, uint256 debt) pure returns (uint256)",
  "function getApproxHint(uint256 cr, uint256 numTrials, uint256 seed) view returns (address hint, uint256 diff, uint256 latestRandomSeed)",
]);
const sortedAbi = parseAbi([
  "function findInsertPosition(uint256 nicr, address prev, address next) view returns (address, address)",
]);

const env = (k: string, d?: string) => {
  const v = process.env[k] ?? d;
  if (v === undefined) throw new Error(`Missing env ${k}`);
  return v;
};

const rpc = env("RPC_URL", "https://rpc.test.mezo.org");
const factory = env("FACTORY") as Address;
const pollMs = Number(env("POLL_SECONDS", "30")) * 1000;
const warnMargin = BigInt(Math.round(Number(env("WARN_MARGIN_PCT", "10")) * 1e16));
const account = privateKeyToAccount(env("PRIVATE_KEY") as `0x${string}`);
const chain = { ...mezoTestnet, rpcUrls: { default: { http: [rpc] } } };
const pub = createPublicClient({ chain, transport: http(rpc) });
const wallet = createWalletClient({ chain, transport: http(rpc), account });

const pct = (x: bigint) => `${(Number(x) / 1e16).toFixed(1)}%`;
const musd = (x: bigint) => `${Number(formatUnits(x, 18)).toFixed(2)} MUSD`;
const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;
const log = (...a: unknown[]) => console.log(new Date().toISOString(), ...a);

async function telegram(text: string) {
  const token = process.env.TELEGRAM_BOT_TOKEN, chat = process.env.TELEGRAM_CHAT_ID;
  if (!token || !chat) return;
  try {
    await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ chat_id: chat, text, disable_web_page_preview: true }),
    });
  } catch (e) {
    log("telegram failed", (e as Error).message);
  }
}

/** Where the loan will sit in Mezo's sorted list after the repayment, so the call stays cheap. */
async function hintsFor(coll: bigint, newDebt: bigint): Promise<[Address, Address]> {
  const nicr = await pub.readContract({ address: MEZO.hintHelpers, abi: hintAbi, functionName: "computeNominalCR", args: [coll, newDebt] });
  const [hint] = await pub.readContract({ address: MEZO.hintHelpers, abi: hintAbi, functionName: "getApproxHint", args: [nicr, 50n, 42n] });
  const [up, low] = await pub.readContract({ address: MEZO.sortedTroves, abi: sortedAbi, functionName: "findInsertPosition", args: [nicr, hint, hint] });
  return [up, low];
}

const warned = new Set<string>();

async function checkVault(vault: Address) {
  const { result } = await pub.simulateContract({ address: vault, abi: vaultAbi, functionName: "previewRescue", account });
  const [canRescue, icr, repay] = result;
  const [trigger, target] = await pub.readContract({ address: vault, abi: vaultAbi, functionName: "rule" });
  if (trigger === 0n) return;

  if (!canRescue) {
    // Warn when the loan drifts toward its trigger, but never right after a rescue left it at its target.
    const near = icr < BigInt(trigger) + warnMargin && icr < BigInt(target) - 5n * 10n ** 15n;
    if (near && icr > 0n && !warned.has(vault.toLowerCase())) {
      warned.add(vault.toLowerCase());
      await telegram(`⚠️ Bulwark vault ${short(vault)} is at ${pct(icr)}, close to its ${pct(BigInt(trigger))} rescue line.`);
    } else if (icr >= BigInt(trigger) + warnMargin) {
      warned.delete(vault.toLowerCase());
    }
    return;
  }

  const [coll, debt] = await pub.readContract({ address: vault, abi: vaultAbi, functionName: "loan" });
  const [up, low] = await hintsFor(coll, debt - repay);
  log(`rescuing ${vault}: ratio ${pct(icr)}, repaying ${musd(repay)}`);

  // Simulate first: another keeper may have got there already.
  const sim = await pub.simulateContract({ address: vault, abi: vaultAbi, functionName: "rescue", args: [up, low], account });
  const hash = await wallet.writeContract({ ...sim.request, gas: 3_000_000n });
  log(`rescue sent for ${vault}: tx ${hash} (the alert goes out when the Rescued event lands)`);
  try {
    const receipt = await pub.waitForTransactionReceipt({ hash, timeout: 120_000 });
    if (receipt.status !== "success") log(`rescue tx reverted ${hash}`);
  } catch (e) {
    log(`still waiting on ${hash}: ${(e as Error).message.split("\n")[0]}`);
  }
}

/** Alerts on every Rescued event from any Bulwark vault, whoever the keeper was. Reads the chain, so a slow RPC can't swallow an alert. */
let lastBlock: bigint | undefined;
async function watchRescues(vaults: readonly Address[]) {
  const head = await pub.getBlockNumber();
  if (lastBlock === undefined) { lastBlock = head; return; }
  if (head <= lastBlock || vaults.length === 0) return;
  const from = head - lastBlock > 9_000n ? head - 9_000n : lastBlock + 1n;
  const logs = await pub.getContractEvents({ address: [...vaults], abi: vaultAbi, eventName: "Rescued", fromBlock: from, toBlock: head });
  lastBlock = head;
  for (const l of logs) {
    const { keeper, icrBefore, icrAfter, repaid, fee } = l.args as { keeper: Address; icrBefore: bigint; icrAfter: bigint; repaid: bigint; fee: bigint };
    warned.add(l.address.toLowerCase());
    const by = keeper.toLowerCase() === account.address.toLowerCase() ? "this keeper" : short(keeper);
    log(`rescued ${l.address}: ${pct(icrBefore)} -> ${pct(icrAfter)}, repaid ${musd(repaid)}, fee ${musd(fee)} to ${by}, tx ${l.transactionHash}`);
    await telegram(
      `🛡️ Bulwark rescued vault ${short(l.address)}\n` +
      `Ratio: ${pct(icrBefore)} → ${pct(icrAfter)}\nRepaid: ${musd(repaid)} from its reserve\n` +
      `Keeper fee: ${musd(fee)} (${by})\n${mezoTestnet.blockExplorers.default.url}/tx/${l.transactionHash}`,
    );
  }
}

async function tick() {
  const vaults = await pub.readContract({ address: factory, abi: factoryAbi, functionName: "allVaults" });
  for (const v of vaults) {
    try {
      await checkVault(v);
    } catch (e) {
      log(`vault ${v}: ${(e as Error).message.split("\n")[0]}`);
    }
  }
  try {
    await watchRescues(vaults);
  } catch (e) {
    log(`rescue watch: ${(e as Error).message.split("\n")[0]}`);
  }
  return vaults.length;
}

async function main() {
  log(`Bulwark keeper ${account.address} watching factory ${factory} on ${rpc}`);
  if (process.argv.includes("--once")) {
    const n = await tick();
    log(`checked ${n} vault(s)`);
    return;
  }
  for (;;) {
    try {
      await tick();
    } catch (e) {
      log("tick failed", (e as Error).message.split("\n")[0]);
    }
    await new Promise((r) => setTimeout(r, pollMs));
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

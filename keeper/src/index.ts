/**
 * Bulwark keeper: watches every Bulwark vault and rescues any loan that falls below
 * its owner's trigger. Anyone can run it; the first keeper to rescue earns the fee.
 *
 * Env: RPC_URL, PRIVATE_KEY, FACTORY, POLL_SECONDS (default 30),
 *      TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID (optional alerts + the two-way Copilot bot), WARN_MARGIN_PCT (default 10)
 */
import "dotenv/config";
import {
  createPublicClient, createWalletClient, defineChain, formatUnits, http, parseAbi, type Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { chatsFor, send, startCopilot } from "./copilot.js";

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
  "function reserve() view returns (uint256)",
  "function VERSION() view returns (uint256)",
  "function poolLocked() returns (bool)",
  "function pendingHarvest() view returns (uint256)",
  "function harvest(address upperHint, address lowerHint) returns (uint256)",
  "function rebalance()",
  "event Rescued(address indexed keeper, uint256 icrBefore, uint256 icrAfter, uint256 repaid, uint256 fee, uint256 price)",
]);
const hintAbi = parseAbi([
  "function computeNominalCR(uint256 coll, uint256 debt) pure returns (uint256)",
  "function getApproxHint(uint256 cr, uint256 numTrials, uint256 seed) view returns (address hint, uint256 diff, uint256 latestRandomSeed)",
]);
const mezoAbi = parseAbi([
  "function fetchPrice() returns (uint256)",
  "function getLast() view returns (address)",
  "function getPrev(address) view returns (address)",
  "function getCurrentICR(address, uint256) view returns (uint256)",
  "function batchLiquidateTroves(address[] borrowers)",
]);
const PRICE_FEED = "0x86bCF0841622a5dAC14A313a15f96A95421b9366" as Address;
const TROVE_MANAGER = "0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0" as Address;
const MCR = 11n * 10n ** 17n;
const HARVEST_MIN = BigInt(Math.round(Number(process.env.HARVEST_MIN_BTC ?? "0.00001") * 1e18));
const sortedAbi = parseAbi([
  "function findInsertPosition(uint256 nicr, address prev, address next) view returns (address, address)",
]);

const env = (k: string, d?: string) => {
  const v = process.env[k] ?? d;
  if (v === undefined) throw new Error(`Missing env ${k}`);
  return v;
};

const rpc = env("RPC_URL", "https://rpc.test.mezo.org");
// One or more factories, comma-separated (v1 and v2 vaults live in different factories).
const factories = env("FACTORY").split(",").map((f) => f.trim()).filter(Boolean) as Address[];
const factory = factories[factories.length - 1];
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

/** Sends to the operator's chat plus every chat watching this vault (see copilot.ts). */
async function telegram(text: string, vault?: string) {
  for (const chat of chatsFor(vault)) {
    try {
      await send(chat, text);
    } catch (e) {
      log("telegram failed", (e as Error).message);
    }
  }
}

/** Where the loan will sit in Mezo's sorted list after the repayment, so the call stays cheap. */
async function hintsFor(coll: bigint, newDebt: bigint): Promise<[Address, Address]> {
  const nicr = await pub.readContract({ address: MEZO.hintHelpers, abi: hintAbi, functionName: "computeNominalCR", args: [coll, newDebt] });
  const [hint] = await pub.readContract({ address: MEZO.hintHelpers, abi: hintAbi, functionName: "getApproxHint", args: [nicr, 50n, 42n] });
  const [up, low] = await pub.readContract({ address: MEZO.sortedTroves, abi: sortedAbi, functionName: "findInsertPosition", args: [nicr, hint, hint] });
  return [up, low];
}

/** Ratio at the last warning per vault. A new warning only fires after a further real drop,
 *  and the warning re-arms only once the loan is clearly back above the warn zone (no flapping). */
const warned = new Map<string, bigint>();
const WARN_STEP = 3n * 10n ** 16n; // 3 percentage points
/** Vaults below their line that can't be rescued (empty reserve); alerted once until fixed. */
const stuck = new Set<string>();

const versions = new Map<string, number>();
async function versionOf(vault: Address) {
  const k = vault.toLowerCase();
  if (!versions.has(k)) {
    try {
      versions.set(k, Number(await pub.readContract({ address: vault, abi: vaultAbi, functionName: "VERSION" })));
    } catch {
      versions.set(k, 1);
    }
  }
  return versions.get(k)!;
}

/**
 * Mezo's Stability Pool refuses withdrawals while any loan sits below 110%. In a crash that
 * can block a v2 vault's earning reserve. Liquidating those loans (anyone may, and the
 * liquidator earns Mezo's liquidation reward) unlocks it. Returns how many were liquidated.
 */
async function unlockPool(): Promise<number> {
  const { result: price } = await pub.simulateContract({ address: PRICE_FEED, abi: mezoAbi, functionName: "fetchPrice", account });
  const list: Address[] = [];
  let cur = await pub.readContract({ address: MEZO.sortedTroves, abi: mezoAbi, functionName: "getLast" });
  while (cur !== "0x0000000000000000000000000000000000000000" && list.length < 30) {
    const icr = await pub.readContract({ address: TROVE_MANAGER, abi: mezoAbi, functionName: "getCurrentICR", args: [cur, price] });
    if (icr >= MCR) break;
    list.push(cur);
    cur = await pub.readContract({ address: MEZO.sortedTroves, abi: mezoAbi, functionName: "getPrev", args: [cur] });
  }
  if (list.length === 0) return 0;
  log(`pool locked: liquidating ${list.length} Mezo loan(s) under 110% to unlock it`);
  const sim = await pub.simulateContract({ address: TROVE_MANAGER, abi: mezoAbi, functionName: "batchLiquidateTroves", args: [list], account });
  const hash = await wallet.writeContract({ ...sim.request, gas: 8_000_000n });
  const receipt = await pub.waitForTransactionReceipt({ hash, timeout: 120_000 });
  log(`liquidation tx ${hash}: ${receipt.status}`);
  return receipt.status === "success" ? list.length : 0;
}

const lastHarvest = new Map<string, number>();
/** Moves BTC a v2 vault's reserve earned into its loan, at most once an hour per vault. */
async function maybeHarvest(vault: Address) {
  const k = vault.toLowerCase();
  if (Date.now() - (lastHarvest.get(k) ?? 0) < 3_600_000) return;
  const pending = await pub.readContract({ address: vault, abi: vaultAbi, functionName: "pendingHarvest" });
  if (pending < HARVEST_MIN) return;
  lastHarvest.set(k, Date.now());
  const [coll, debt] = await pub.readContract({ address: vault, abi: vaultAbi, functionName: "loan" });
  const [up, low] = await hintsFor(coll + pending, debt);
  const sim = await pub.simulateContract({ address: vault, abi: vaultAbi, functionName: "harvest", args: [up, low], account });
  const hash = await wallet.writeContract({ ...sim.request, gas: 3_000_000n });
  await pub.waitForTransactionReceipt({ hash, timeout: 120_000 });
  log(`harvested ${formatUnits(pending, 18)} BTC into ${vault}: tx ${hash}`);
  await telegram(
    `🌱 Vault ${short(vault)}'s reserve earned ${formatUnits(pending, 18)} BTC in Mezo's Stability Pool. ` +
    `It's now in the loan as extra collateral.\n${mezoTestnet.blockExplorers.default.url}/tx/${hash}`,
    vault,
  );
}

async function checkVault(vault: Address) {
  const v2 = (await versionOf(vault)) >= 2;
  if (v2) {
    // Unlock the pool first when this vault needs a rescue and its earning reserve is stuck.
    const [{ result: pre }, [trig]] = await Promise.all([
      pub.simulateContract({ address: vault, abi: vaultAbi, functionName: "previewRescue", account }),
      pub.readContract({ address: vault, abi: vaultAbi, functionName: "rule" }),
    ]);
    if (trig > 0n && pre[1] > 0n && pre[1] < BigInt(trig)) {
      const { result: locked } = await pub.simulateContract({ address: vault, abi: vaultAbi, functionName: "poolLocked", account });
      if (locked) await unlockPool().catch((e) => log(`unlock failed: ${(e as Error).message.split("\n")[0]}`));
    }
  }

  const { result } = await pub.simulateContract({ address: vault, abi: vaultAbi, functionName: "previewRescue", account });
  const [canRescue, icr, repay] = result;
  const [trigger, target] = await pub.readContract({ address: vault, abi: vaultAbi, functionName: "rule" });
  if (trigger === 0n) return;

  if (!canRescue) {
    const key = vault.toLowerCase();
    // Below the line but nothing to rescue with: the reserve is empty or too small.
    if (icr > 0n && icr < BigInt(trigger)) {
      if (!stuck.has(key)) {
        stuck.add(key);
        const res = await pub.readContract({ address: vault, abi: vaultAbi, functionName: "reserve" });
        await telegram(
          `🚨 Bulwark vault ${short(vault)} is at ${pct(icr)}, BELOW its ${pct(BigInt(trigger))} rescue line, ` +
          `but its reserve (${musd(res)}) is too small to rescue it.\n` +
          `Top up the reserve or add BTC now. Mezo liquidates below 110%.`,
          vault,
        );
      }
      return;
    }
    stuck.delete(key);
    // Warn when the loan drifts toward its trigger, but never right after a rescue left it at its target.
    const near = icr < BigInt(trigger) + warnMargin && icr < BigInt(target) - 5n * 10n ** 15n;
    const last = warned.get(key);
    if (near && icr > 0n && (last === undefined || icr <= last - WARN_STEP)) {
      warned.set(key, icr);
      await telegram(`⚠️ Bulwark vault ${short(vault)} is at ${pct(icr)}, close to its ${pct(BigInt(trigger))} rescue line.`, vault);
    } else if (icr >= BigInt(trigger) + warnMargin + WARN_STEP) {
      warned.delete(key);
    }
    return;
  }

  stuck.delete(vault.toLowerCase());
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
    else if (v2) {
      // Top the on-hand share back up from the pool for the next rescue.
      const sim2 = await pub.simulateContract({ address: vault, abi: vaultAbi, functionName: "rebalance", account }).catch(() => null);
      if (sim2) await wallet.writeContract({ ...sim2.request, gas: 2_000_000n }).catch(() => {});
    }
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
    warned.set(l.address.toLowerCase(), icrAfter);
    const by = keeper.toLowerCase() === account.address.toLowerCase() ? "this keeper" : short(keeper);
    log(`rescued ${l.address}: ${pct(icrBefore)} -> ${pct(icrAfter)}, repaid ${musd(repaid)}, fee ${musd(fee)} to ${by}, tx ${l.transactionHash}`);
    await telegram(
      `🛡️ Bulwark rescued vault ${short(l.address)}\n` +
      `Ratio: ${pct(icrBefore)} → ${pct(icrAfter)}\nRepaid: ${musd(repaid)} from its reserve\n` +
      `Keeper fee: ${musd(fee)} (${by})\n${mezoTestnet.blockExplorers.default.url}/tx/${l.transactionHash}`,
      l.address,
    );
  }
}

async function allVaults(): Promise<Address[]> {
  const lists = await Promise.all(factories.map((f) => pub.readContract({ address: f, abi: factoryAbi, functionName: "allVaults" })));
  return lists.flat();
}

async function tick() {
  const vaults = await allVaults();
  for (const v of vaults) {
    try {
      await checkVault(v);
      if ((await versionOf(v)) >= 2) await maybeHarvest(v);
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
  log(`Bulwark keeper ${account.address} watching factory ${factories.join(", ")} on ${rpc}`);
  if (process.argv.includes("--once")) {
    const n = await tick();
    log(`checked ${n} vault(s)`);
    return;
  }
  startCopilot({ pub: pub as never, factories, account: account.address, log }).catch((e) => log("copilot stopped", (e as Error).message));
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

/**
 * Bulwark Copilot: the keeper's Telegram bot, now two-way.
 *
 * Anyone can message the bot. /watch links a chat to a vault (by vault address or by the
 * owner's wallet), and from then on that chat gets the vault's alerts too, and can ask:
 *   /status        how safe the loan is, in plain words
 *   /whatif 20     what happens if BTC drops 20%
 *   /rescues       the last rescues on this vault
 *   /topup         a link to fill the reserve
 * Plain questions work too ("how safe is my loan?", "what if btc drops 30%?").
 *
 * Everything is read from the chain; the bot never holds anyone's keys.
 */
import { readFileSync, writeFileSync } from "node:fs";
import { formatUnits, isAddress, parseAbi, zeroAddress, type Address, type PublicClient } from "viem";

const DASHBOARD = "https://cipoklean.eu.cc/bulwark/";
const EXPLORER = "https://explorer.test.mezo.org";
const EXPLORER_API = "https://api.explorer.test.mezo.org/api/v2";
const LIQUIDATION = 1.1;

const vaultAbi = parseAbi([
  "function previewRescue() returns (bool canRescue, uint256 icr, uint256 repay, uint256 fee)",
  "function loan() view returns (uint256 coll, uint256 debt)",
  "function rule() view returns (uint64 triggerICR, uint64 targetICR, uint16 feeBps)",
  "function reserve() view returns (uint256)",
  "function owner() view returns (address)",
  "function rescueCount() view returns (uint256)",
  "function reserveEarning() view returns (uint256)",
  "function pendingHarvest() view returns (uint256)",
  "function totalHarvested() view returns (uint256)",
  "function earning() view returns (bool)",
]);
const factoryAbi = parseAbi([
  "function vaultOf(address) view returns (address)",
  "function allVaults() view returns (address[])",
]);
const boAbi = parseAbi([
  "function minNetDebt() view returns (uint256)",
  "function MUSD_GAS_COMPENSATION() view returns (uint256)",
]);
const BORROWER_OPS = "0xCdF7028ceAB81fA0C6971208e83fa7872994beE5" as Address;

type Ctx = { pub: PublicClient; factories: Address[]; account: Address; log: (...a: unknown[]) => void };

const num = (x: bigint) => Number(formatUnits(x, 18));
const p1 = (x: number) => `${(x * 100).toFixed(1)}%`;
const m2 = (x: number) => `${x.toLocaleString("en-US", { maximumFractionDigits: 2, minimumFractionDigits: 2 })} MUSD`;
const usd = (x: number) => `$${Math.round(x).toLocaleString("en-US")}`;
const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;

// ---------------------------------------------------------------- watchers (chat -> vault)

const STATE_FILE = new URL("../copilot-state.json", import.meta.url);
let watchers: Record<string, string> = {}; // chatId -> vault
try { watchers = JSON.parse(readFileSync(STATE_FILE, "utf8")); } catch { /* first run */ }
const save = () => writeFileSync(STATE_FILE, JSON.stringify(watchers, null, 2));

/** Chats that should hear about this vault: the operator's chat plus everyone watching it. */
export function chatsFor(vault?: string): string[] {
  const out = new Set<string>();
  if (process.env.TELEGRAM_CHAT_ID) out.add(process.env.TELEGRAM_CHAT_ID);
  if (vault) for (const [chat, v] of Object.entries(watchers)) if (v.toLowerCase() === vault.toLowerCase()) out.add(chat);
  return [...out];
}

export async function send(chat: string, text: string) {
  const token = process.env.TELEGRAM_BOT_TOKEN;
  if (!token) return;
  await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ chat_id: chat, text, disable_web_page_preview: true }),
  });
}

// ---------------------------------------------------------------- reading a vault

async function snapshot(ctx: Ctx, vault: Address) {
  const { pub } = ctx;
  const [{ result: [, icrRaw] }, [coll, debt], [trig, tgt, feeBps], res, minNet, gasComp] = await Promise.all([
    pub.simulateContract({ address: vault, abi: vaultAbi, functionName: "previewRescue", account: ctx.account }),
    pub.readContract({ address: vault, abi: vaultAbi, functionName: "loan" }),
    pub.readContract({ address: vault, abi: vaultAbi, functionName: "rule" }),
    pub.readContract({ address: vault, abi: vaultAbi, functionName: "reserve" }),
    pub.readContract({ address: BORROWER_OPS, abi: boAbi, functionName: "minNetDebt" }),
    pub.readContract({ address: BORROWER_OPS, abi: boAbi, functionName: "MUSD_GAS_COMPENSATION" }),
  ]);
  const s = {
    icr: num(icrRaw), coll: num(coll), debt: num(debt), trigger: num(trig), target: num(tgt),
    fee: Number(feeBps) / 10_000, reserve: num(res), floor: num(minNet) + num(gasComp) + 1,
    price: 0,
  };
  s.price = s.coll > 0 ? (s.icr * s.debt) / s.coll : 0;
  return s;
}
type Snap = Awaited<ReturnType<typeof snapshot>>;

/** What a rescue would repay at a given BTC price, with the same caps the contract uses. */
function rescueAt(s: Snap, price: number) {
  const icr = (s.coll * price) / s.debt;
  if (s.target === 0 || icr >= s.trigger) return { icr, needed: 0, repay: 0, after: icr };
  const needed = s.debt - (s.coll * price) / s.target;
  let repay = Math.min(needed, Math.max(0, s.debt - s.floor));
  repay = Math.min(repay, s.reserve / (1 + s.fee));
  const after = (s.coll * price) / (s.debt - repay);
  return { icr, needed, repay, after };
}

function verdict(s: Snap) {
  if (s.debt === 0) return "This vault has no open loan.";
  if (s.target === 0) return "⚠️ No rescue rule is set, so no keeper can help this loan.";
  const atTrigger = s.debt * (1 - s.trigger / s.target) * (1 + s.fee); // reserve a full rescue needs
  if (s.icr < s.trigger) {
    return s.reserve < 1
      ? "🚨 Below the rescue line and the reserve is empty. Top up or add BTC now."
      : "🟠 Below the rescue line. A keeper should rescue it within a minute.";
  }
  if (s.reserve < 1) return "🟠 Healthy for now, but the reserve is empty, so nobody can rescue it.";
  if (s.reserve < atTrigger) return `🟡 Healthy, but the reserve covers only part of a rescue. Add about ${m2(atTrigger - s.reserve)} for a full one.`;
  return "🟢 Healthy, and the reserve covers a full rescue.";
}

async function statusText(ctx: Ctx, vault: Address) {
  const s = await snapshot(ctx, vault);
  if (s.debt === 0) return `Vault ${short(vault)} has no open loan.`;
  const trigPrice = (s.price * s.trigger) / s.icr;
  const liqPrice = (s.price * LIQUIDATION) / s.icr;
  return [
    `🛡️ Vault ${short(vault)}`,
    verdict(s),
    ``,
    `Health: ${p1(s.icr)} (rescue at ${p1(s.trigger)}, back to ${p1(s.target)})`,
    `BTC now: ${usd(s.price)}`,
    `Rescue starts if BTC hits ${usd(trigPrice)} (−${p1(1 - trigPrice / s.price)})`,
    `Liquidation if BTC hits ${usd(liqPrice)} (−${p1(1 - liqPrice / s.price)})`,
    `Loan: ${s.coll.toFixed(4)} BTC backing ${m2(s.debt)}`,
    `Reserve: ${m2(s.reserve)}`,
    ...(await earningLines(ctx, vault)),
    ``,
    `Try /whatif 20 to see a 20% BTC drop.`,
  ].join("\n");
}

/** v2 vaults: how much of the reserve is earning, and the BTC it has earned. v1 vaults: nothing. */
async function earningLines(ctx: Ctx, vault: Address): Promise<string[]> {
  try {
    const [on, inPool, pending, harvested] = await Promise.all([
      ctx.pub.readContract({ address: vault, abi: vaultAbi, functionName: "earning" }),
      ctx.pub.readContract({ address: vault, abi: vaultAbi, functionName: "reserveEarning" }),
      ctx.pub.readContract({ address: vault, abi: vaultAbi, functionName: "pendingHarvest" }),
      ctx.pub.readContract({ address: vault, abi: vaultAbi, functionName: "totalHarvested" }),
    ]);
    if (!on && inPool === 0n) return ["Earning: off"];
    const btc = num(pending + harvested);
    return [`Earning: ${m2(num(inPool))} in Mezo's Stability Pool, ${btc > 0 ? btc.toFixed(8) + " BTC earned so far" : "no BTC earned yet"}`];
  } catch {
    return [];
  }
}

async function whatIfText(ctx: Ctx, vault: Address, dropPct: number) {
  const s = await snapshot(ctx, vault);
  if (s.debt === 0) return `Vault ${short(vault)} has no open loan.`;
  const price = s.price * (1 - dropPct / 100);
  const r = rescueAt(s, price);
  const lines = [`📉 If BTC drops ${dropPct}% to ${usd(price)}:`, `Health goes ${p1(s.icr)} → ${p1(r.icr)}.`];
  if (r.icr >= s.trigger) {
    lines.push(`That's still above your ${p1(s.trigger)} line, so nothing happens.`);
  } else if (r.repay < 0.01) {
    lines.push(`That's below your line, but the reserve (${m2(s.reserve)}) is too small to rescue it.`);
    lines.push(r.icr < LIQUIDATION ? "❌ Below 110%, Mezo would liquidate this loan." : "You'd need to top up or add BTC yourself.");
  } else {
    const full = r.repay >= r.needed - 0.01;
    lines.push(`A keeper repays ${m2(r.repay)} from your reserve, lifting health to ${p1(r.after)}${full ? " ✅" : ""}.`);
    if (!full) lines.push(`That's a partial rescue: a full one needs ${m2(r.needed * (1 + s.fee))}.`);
    if (r.after < LIQUIDATION) lines.push("❌ Even after that it's below 110%, so Mezo would liquidate it.");
  }
  return lines.join("\n");
}

async function rescuesText(vault: Address) {
  const res = await fetch(`${EXPLORER_API}/addresses/${vault}/logs`);
  const data = (await res.json()) as { items?: { decoded?: { method_call?: string; parameters?: { name: string; value: string }[] }; transaction_hash: string; block_timestamp?: string }[] };
  const items = (data.items ?? []).filter((l) => l.decoded?.method_call?.startsWith("Rescued")).slice(0, 3);
  if (items.length === 0) return `No rescues on ${short(vault)} yet.`;
  const lines = [`Last ${items.length} rescue(s) on ${short(vault)}:`];
  for (const l of items) {
    const p = Object.fromEntries((l.decoded?.parameters ?? []).map((x) => [x.name, x.value]));
    const when = l.block_timestamp ? new Date(l.block_timestamp).toUTCString().slice(5, 22) + " UTC" : "";
    lines.push(`• ${when}: ${p1(Number(p.icrBefore) / 1e18)} → ${p1(Number(p.icrAfter) / 1e18)}, repaid ${m2(Number(p.repaid) / 1e18)}\n  ${EXPLORER}/tx/${l.transaction_hash}`);
  }
  return lines.join("\n");
}

const HELP = [
  "I'm the Bulwark Copilot. I watch Bulwark vaults on Mezo and tell you how safe your loan is.",
  "",
  "/watch <vault or wallet address>: link this chat to your vault (you'll get its alerts too)",
  "/status: how safe the loan is right now",
  "/whatif 20: what happens if BTC drops 20%",
  "/rescues: the last rescues",
  "/topup: fill your reserve",
  "",
  "You can also just ask: \"how safe is my loan?\" or \"what if btc drops 30%?\"",
].join("\n");

// ---------------------------------------------------------------- routing

async function allVaults(ctx: Ctx): Promise<Address[]> {
  const lists = await Promise.all(ctx.factories.map((f) => ctx.pub.readContract({ address: f, abi: factoryAbi, functionName: "allVaults" })));
  return lists.flat();
}

/** A vault address, or the owner's wallet (newest factory first, so a v2 vault wins). */
async function resolveVault(ctx: Ctx, addr: Address): Promise<Address | null> {
  const all = await allVaults(ctx);
  if (all.some((v) => v.toLowerCase() === addr.toLowerCase())) return addr;
  for (const f of [...ctx.factories].reverse()) {
    const v = await ctx.pub.readContract({ address: f, abi: factoryAbi, functionName: "vaultOf", args: [addr] });
    if (v !== zeroAddress) return v;
  }
  return null;
}

async function vaultForChat(ctx: Ctx, chat: string): Promise<Address | null> {
  if (watchers[chat]) return watchers[chat] as Address;
  if (chat === process.env.TELEGRAM_CHAT_ID) {
    const all = await allVaults(ctx);
    if (all.length >= 1) return all[all.length - 1];
  }
  return null;
}

export async function reply(ctx: Ctx, chat: string, raw: string): Promise<string> {
  const text = raw.trim();
  const lower = text.toLowerCase();
  const cmd = lower.startsWith("/") ? lower.split(/[\s@]/)[0] : "";
  const addr = text.match(/0x[0-9a-fA-F]{40}/)?.[0];

  if (cmd === "/start" || cmd === "/help" || /^(hi|hey|hello|help|menu)\b/.test(lower)) return HELP;

  if (cmd === "/watch" || (!cmd && addr)) {
    if (!addr || !isAddress(addr)) return "Send /watch followed by your vault address or the wallet that owns it.";
    const v = await resolveVault(ctx, addr as Address);
    if (!v) return "I couldn't find a Bulwark vault for that address. Open one at " + DASHBOARD;
    watchers[chat] = v;
    save();
    return `✅ Watching vault ${short(v)}. You'll get its alerts here.\n\n` + (await statusText(ctx, v));
  }
  if (cmd === "/unwatch") {
    delete watchers[chat];
    save();
    return "Stopped watching. Send /watch <address> any time.";
  }

  const vault = await vaultForChat(ctx, chat);
  const needVault = "First tell me which vault: /watch <vault or wallet address>";

  if (cmd === "/topup" || /\b(top ?up|refill|fill)\b/.test(lower)) {
    return `Fill your reserve here (Manage → Top up reserve): ${DASHBOARD}` + (vault ? `\nVault: ${vault}` : "");
  }
  const drop = lower.match(/(\d+(?:\.\d+)?)\s*%/)?.[1] ?? (cmd === "/whatif" ? lower.split(/\s+/)[1] : undefined);
  if (cmd === "/whatif" || /\b(drops?|dumps?|crash(es)?|falls?|down|what ?if)\b/.test(lower)) {
    if (!vault) return needVault;
    const d = Number(drop);
    if (drop === undefined) {
      const out = await Promise.all([10, 20, 30].map((x) => whatIfText(ctx, vault, x)));
      return out.join("\n\n") + "\n\nPick your own: /whatif 25";
    }
    if (!Number.isFinite(d) || d <= 0 || d >= 100) return "Tell me how far BTC drops, like /whatif 20";
    return whatIfText(ctx, vault, d);
  }
  if (cmd === "/rescues" || /\brescue(s|d)?\b.*\b(last|recent|history)\b|\bhistory\b/.test(lower)) {
    if (!vault) return needVault;
    return rescuesText(vault);
  }
  if (cmd === "/status" || /\b(safe|health|status|ratio|risk|liquidat|ok)\b/.test(lower)) {
    if (!vault) return needVault;
    return statusText(ctx, vault);
  }
  return "I didn't catch that.\n\n" + HELP;
}

/** Long-polls Telegram for messages and answers them. Runs beside the keeper loop. */
export async function startCopilot(ctx: Ctx) {
  const token = process.env.TELEGRAM_BOT_TOKEN;
  if (!token) return;
  const api = `https://api.telegram.org/bot${token}`;
  await fetch(`${api}/setMyCommands`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ commands: [
      { command: "status", description: "How safe is my loan?" },
      { command: "whatif", description: "What if BTC drops? e.g. /whatif 20" },
      { command: "rescues", description: "Last rescues" },
      { command: "topup", description: "Fill my reserve" },
      { command: "watch", description: "Link a vault: /watch <address>" },
      { command: "help", description: "What I can do" },
    ] }),
  }).catch(() => {});
  ctx.log("copilot: listening for Telegram messages");
  let offset = 0;
  for (;;) {
    try {
      const r = await fetch(`${api}/getUpdates?timeout=50&offset=${offset}&allowed_updates=["message"]`);
      const data = (await r.json()) as { ok: boolean; result?: { update_id: number; message?: { chat: { id: number }; text?: string } }[] };
      for (const u of data.result ?? []) {
        offset = u.update_id + 1;
        const chat = u.message?.chat.id, text = u.message?.text;
        if (chat === undefined || !text) continue;
        let out: string;
        try {
          out = await reply(ctx, String(chat), text);
        } catch (e) {
          ctx.log("copilot reply failed", (e as Error).message.split("\n")[0]);
          out = "Sorry, I couldn't read the chain just now. Try again in a minute.";
        }
        await send(String(chat), out);
      }
    } catch (e) {
      ctx.log("copilot poll failed", (e as Error).message.split("\n")[0]);
      await new Promise((res) => setTimeout(res, 5000));
    }
  }
}

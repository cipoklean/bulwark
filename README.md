# 🛡️ Bulwark

**Keep your Bitcoin-backed MUSD loan out of liquidation, even while you sleep.**

Bulwark is a safety net for people who borrow MUSD against their BTC on [Mezo](https://mezo.org). You keep a small MUSD buffer inside your own vault and set a simple rule. If BTC drops and your loan gets too close to the edge, anyone running the Bulwark keeper can step in and repay part of your debt from that buffer. The contract checks everything on-chain, so nobody can rescue you when you don't need it or take more than you allowed.

Built solo by [@cipoklean](https://github.com/cipoklean) for the Mezo Buildathon (3rd edition, DeFi track).

- **Live dashboard:** https://cipoklean.eu.cc/bulwark/
- **Network:** Mezo testnet (chain 31611)
- **Factory:** [`0x68Eb65479E3396548113F307d11C8Bd66e59025a`](https://explorer.test.mezo.org/address/0x68Eb65479E3396548113F307d11C8Bd66e59025a)
- **Example vault:** [`0xdeC65c629311925074Cc1277cE7f9c6ffD6278e5`](https://explorer.test.mezo.org/address/0xdeC65c629311925074Cc1277cE7f9c6ffD6278e5)

---

## Why I built this

When you borrow MUSD on Mezo, your loan has a health number called the collateral ratio: your BTC's value divided by what you owe. If it falls below **110%**, your loan can be liquidated and you lose your BTC.

BTC can drop 10% while you're asleep, at work, or just off your phone. Most people don't lose their BTC because they borrowed too much. They lose it because they weren't there at the wrong moment.

I wanted something that is **there at the wrong moment for you**, without handing your keys or your BTC to anyone.

## How it works, in plain words

1. **You open your loan through your own Bulwark vault.** You put in BTC and borrow MUSD as usual. Part of that MUSD stays in the vault as a rescue buffer; the rest goes to your wallet.
2. **You set your rule.** For example: *"If my ratio drops below 160%, repay enough to bring it back to 175%, and pay whoever does it 0.5%."*
3. **Keepers keep watch.** A small bot (included here) checks every vault every 30 seconds. Anyone can run one.
4. **If BTC falls past your line, a keeper calls `rescue`.** The contract reads the live price from Mezo's own oracle, checks that you really are below your trigger, works out exactly how much to repay, repays it from your buffer, and pays the keeper their small fee.
5. **You get a Telegram message** telling you what happened, with a link to the transaction.

You stay in control the whole time. Only you can change the rule, withdraw the buffer, borrow more, take out BTC, or close the loan.

### Built-in safety limits

These are written into the contract, not just promised:

| Limit | Why |
|---|---|
| Keeper fee can never be more than **2%** | Keepers can't drain your buffer. |
| Trigger can never be below **115%** | Rescues happen before Mezo's 110% liquidation line, not after. |
| Target must be **above** the trigger | A rescue always makes your loan healthier. |
| Rescue only works **below your trigger** | Nobody can "rescue" a healthy loan. |
| Rescue must **raise** your ratio, or it reverts | Checked after every rescue. |
| Never repays below Mezo's minimum debt (2,000 MUSD) | Mezo would reject it; Bulwark repays what it can. |
| One vault per person | Mezo ties each loan to one address, so every user gets their own vault. |

## See it working (2 minutes, no setup)

1. Open the **[live dashboard](https://cipoklean.eu.cc/bulwark/)**.
2. You'll see a real vault on Mezo testnet: its health ratio, BTC price, debt, and buffer.
3. Look at **"What BTC must do"**. It shows the price where a rescue kicks in, where you'd be liquidated without Bulwark, and how much further BTC can fall once the buffer is used.
4. Scroll to **Activity** to see every on-chain event for that vault, each linked to the explorer.
5. **All Bulwark vaults** lists every vault the keeper is watching. Tap one to view it.

## Try it yourself on testnet

You'll need a browser wallet (MetaMask, Rabby, or OKX) and some free test BTC.

### Step 1: Get test BTC
Go to the [Mezo faucet](https://faucet.test.mezo.org/) and claim test BTC. You need about **0.05 BTC**, because Mezo's smallest loan is roughly 2,000 MUSD.

### Step 2: Connect
Open the dashboard and tap **Connect wallet**. It will offer to add Mezo testnet to your wallet if you don't have it yet.

### Step 3: Open your vault
If you don't have a vault yet, an **"Open your own vault"** box appears. Enter:
- **BTC:** how much collateral to lock (for example 0.05)
- **Borrow:** how much MUSD to borrow (at least about 1,800)
- **Reserve:** how much of that MUSD to keep as your rescue buffer (for example 400)

Tap **Create vault & open loan** and approve the transactions. Bulwark sets a starter rule for you: rescue below 160%, back to 175%, 0.5% fee.

### Step 4: Tune your rule
In **Your rule**, change the trigger, target, and fee, then tap **Save rule**.

> **Want to watch a rescue happen?** Set your trigger *above* your current ratio. For example, if you're at 170%, set trigger 175% and target 185%. Your loan is now "below the line", and the Rescue button lights up. Press it yourself and earn the fee, or let the keeper do it within 30 seconds.

### Step 5: Top up the buffer any time
Use **Add to reserve** to put more MUSD in. Anyone can top up anyone's buffer, so a friend or a DAO can protect a loan too.

## Run your own keeper (and earn fees)

Keepers are what make Bulwark work without me being online. Anyone can run one, and the first keeper to rescue a loan earns its fee.

You need Node.js 18 or newer and a wallet with a little test BTC for gas.

```bash
git clone https://github.com/cipoklean/bulwark.git
cd bulwark
bash keeper/start.sh
```

It asks for your keeper wallet's private key at a hidden prompt, saves it to `keeper/.env` (readable only by you, never committed), and starts watching in the background.

```bash
tail -f keeper/keeper.log      # watch it work
bash keeper/start.sh stop      # stop it
```

### Get alerts on Telegram
1. In Telegram, message **@BotFather**, send `/newbot`, and copy the token it gives you.
2. Send your new bot any message, like "hi".
3. Run:
   ```bash
   bash keeper/telegram-setup.sh
   ```
   Paste the token at the hidden prompt. It finds your chat, sends a test message, and restarts the keeper.

From then on you'll get a warning when a vault gets close to its trigger, and a message after every rescue.

## Deploy your own copy

`script/deploy.sh` does everything in one go: deploys the factory, creates your vault, sizes a loan to fit your wallet, and sets the rule.

```bash
bash script/deploy.sh
```

It installs Foundry if needed, asks for your key at a hidden prompt, and checks your balance first. If you don't have enough BTC it stops before spending anything and tells you how much you need.

Optional settings (environment variables): `COLL`, `BORROW`, `RESERVE`, `TRIGGER`, `TARGET`, `FEE_BPS`, `GAS_KEEP`, and `FACTORY` (reuse an existing factory instead of deploying a new one).

## For developers

### What's in the repo

```
src/BulwarkVault.sol      one vault per user: owns the Mezo loan, holds the buffer, enforces the rule
src/BulwarkFactory.sol    creates vaults and lists them all for keepers
src/interfaces/IMezo.sol  the slices of Mezo's contracts Bulwark talks to
test/Bulwark.t.sol        9 tests on a fork of Mezo testnet
test/Gates.t.sol          the early "is this even possible?" checks
keeper/src/index.ts       the keeper bot (TypeScript + viem)
keeper/start.sh           run the keeper in the background
keeper/telegram-setup.sh  link Telegram alerts
script/deploy.sh          one-command deploy
script/live-gate.sh       the first live proof on Mezo testnet
docs/index.html           the dashboard (one file, no build step)
```

### Run the tests

```bash
forge test --match-contract BulwarkTest
```

The tests run on a fork of Mezo testnet against Mezo's real BorrowerOperations, TroveManager, and MUSD contracts. They cover:

- Opening a loan and sending the extra MUSD to the owner
- Refusing to rescue a healthy loan
- A real rescue after BTC falls from $80,000 to $48,000 (149% → 180%, repaying 536 MUSD, keeper earns 2.68 MUSD)
- A partial rescue when the buffer is small
- Respecting Mezo's minimum debt
- Owner-only controls
- Rejecting unsafe rules
- Anyone being able to add BTC
- Closing the loan and getting all the BTC back

One honest note: Mezo's price oracle is a special built-in contract (a precompile) that doesn't run on a local fork, so the tests put a mock oracle at that address. To make sure that wasn't hiding anything, I also ran the full flow **live on Mezo testnet with the real oracle** before building the rest.

### Mezo contracts used (testnet)

| Contract | Address |
|---|---|
| BorrowerOperations | `0xCdF7028ceAB81fA0C6971208e83fa7872994beE5` |
| TroveManager | `0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0` |
| MUSD | `0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503` |
| PriceFeed | `0x86bCF0841622a5dAC14A313a15f96A95421b9366` |
| HintHelpers | `0x4e4cBA3779d56386ED43631b4dCD6d8EacEcBCF6` |
| SortedTroves | `0x722E4D24FD6Ff8b0AC679450F3D91294607268fA` |
| Oracle precompile | `0x7b7c000000000000000000000000000000000015` |

## How MUSD is used

MUSD isn't a side feature here. It *is* the safety mechanism:

- Users **borrow MUSD** from Mezo through their vault.
- The rescue buffer is **held in MUSD**.
- Rescues **repay MUSD debt** on Mezo.
- Keepers are **paid in MUSD**.

## What's next (Wave 2)

Wave 1 is about one thing done properly: liquidation protection. Next up:

- **Rescue with BTC as well as MUSD**, for people who'd rather top up collateral than repay
- **Redemption awareness**: warn users when their loan is near the front of Mezo's redemption queue (research first, so I don't overpromise)
- **Put the idle buffer to work** in a safe yield source, without making rescues slower
- **Mezo Passport** sign-in in the dashboard
- **Keeper leaderboard** and a Telegram assistant you can ask "how safe is my loan?"
- An independent review of the contracts before anything touches mainnet

## Disclaimer

Bulwark is a hackathon project running on Mezo **testnet**. It hasn't been audited. Please don't use it with real funds.

## License

MIT

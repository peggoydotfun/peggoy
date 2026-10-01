# PEGGOY · architecture

**Drop the ball. Every peg pays.**
A pegboard arcade machine on Robinhood Chain. Stake $PEGGOY, your stake earns *balls* over time, ETH from the
creator tax streams to stakers and a weekly Drop pays out prizes picked by public, verifiable randomness.

Site: **https://peggoy.fun** · Launch: **Sat 03 Oct 2026 · 15:00 UTC** (22:00 WIB · 11:00 ET). $PEGGOY goes live on Pons; the Machine opens on mainnet.

---

## 1 · Concept

| | |
|---|---|
| **Token** | $PEGGOY, launched on Pons (Robinhood Chain, chain id 4663) |
| **Machine** | Single staking contract. Stake $PEGGOY, withdraw anytime, no lock |
| **Balls** | `balls = stake × seconds staked`. Linear, so splitting a stake across 1,000 wallets earns *exactly* the same balls as one wallet |
| **Stream (80%)** | 80% of every ETH that reaches the Machine streams to stakers pro rata over 7 days |
| **Drop (20%)** | 20% builds the weekly Drop. Every Saturday 15:00 UTC, winners are drawn weighted by balls earned that week |
| **Drop slots** | 1 × 40% · 3 × 10% · 10 × 3% of the weekly pot (the pegboard's slot row) |
| **No ticket for free** | There is no free-signature airdrop. Free entries get farmed by design, so nothing is given for them |

Pre-launch (now to 03 Oct): the site shows the countdown, the rules, the contract source and a playable
pegboard in **practice mode** (browser only, no wallet, no prize). Wallet connect opens at launch.

---

## 2 · Gaps we close (from the NIMORI review)

| # | Gap seen in NIMORI | What PEGGOY does instead |
|---|---|---|
| 1 | Entry list lives in the team's Blob store, cannot be verified | No off-chain list. Every weight is a `Staked`/`Withdrawn` event on chain. Anyone recomputes balls from logs |
| 2 | Sybil is cheap (1 tx + dust gas = 1 ticket) | Balls are linear in stake × time. Splitting gives zero advantage. No free entries exist |
| 3 | Randomness from an L2 block hash (sequencer can influence it) | **drand** `evmnet` (League of Entropy) only, BLS on BN254 verified on chain. No block hash mixed in: whoever settles or the sequencer could nudge it |
| 4 | Team picks the snapshot block | The round follows from the schedule: the first drand round published after the week closes. Balls are frozen at the same moment. Nobody chooses either |
| 5 | 24-bit ticket codes collide (~2% at 800 entries) | Winners are addresses. No short codes |
| 6 | `kick()` dust griefing delays real rewards 7 days | `roll()` needs `queued ≥ MIN_ROLL` (0.01 ETH) **or** the period ended; anyone can roll mid-period above the threshold, leftover rolls in |
| 7 | Owner = one EOA, can stretch rewards | Owner = Safe 2-of-3 behind a 48 h timelock. No owner path to stakes or streamed ETH. The Drop distributor is appointed **once** through the timelock (48 h public notice) and can never be swapped; unreleased pots roll forward by anyone after 30 days |
| 8 | `rescueQueued` when totalSupply = 0 | Removed. ETH with no stakers waits in the queue for the first staker |
| 9 | Read API: race → 500, uncached listings, open RPC proxy | No database, no API, no proxy of ours: reads go to a CORS-enabled public RPC, writes through the user's wallet |
| 10 | Wallet: stale `accountsChanged` listener, unescaped EIP-6963 name/icon | One listener per provider, removed on disconnect. All injected strings escaped; icons only as `data:image/` |
| 11 | No CSP, no frame protection | Strict CSP (self + the 3 CDNs), `frame-ancestors 'none'`, `Permissions-Policy` |
| 12 | 3D loop renders 60 fps forever | Render on demand: paused offscreen (IntersectionObserver) and on `prefers-reduced-motion` |
| 13 | SECURITY.md said "nothing deployed" after deploy | Addresses live in one `deployments.json`, read by site, docs and scripts |

---

## 3 · System

```
                 ┌────────────────────────── Robinhood Chain (4663) ──────────────────────────┐
 Pons launch ──▶ │ $PEGGOY (ERC-20, Pons V2)                                                   │
 creator tax ETH │      │ stake / withdraw                                                    │
       │         │      ▼                                                                     │
       └────────▶│ PeggoyMachine ── 80% ──▶ Stream (7-day rate, Synthetix-style, MIN_ROLL)     │
                 │      │                                                                     │
                 │      └─ 20% ──▶ dropPot[week] ──▶ PeggoyDrop: settle (drand BLS) ─▶ enter ─▶ claim │
                 │                                   ▲                    │                    │
                 │ Safe 2/3 ──▶ Timelock 48h ──▶ params only          winners claim (pull)    │
                 └───────────────────────────────────┼────────────────────────────────────────┘
                                                     │ signature for round R (anyone can submit)
                                        drand evmnet beacon (public)

 Browser ──▶ peggoy.fun (static, VPS + nginx) ──▶ public RPC (CORS, read-only use)
        └──▶ wallet (EIP-6963): approve, stake, withdraw, claim, exit, roll
```

### Contracts (Foundry, solc 0.8.26)

**`PeggoyMachine.sol`** (41 tests across both suites)
- `stake` / `withdraw` / `claim` / `claimTo` / `exit`: balance-delta crediting (taxed tokens), `nonReentrant`, no pause.
- `receive()`: splits `msg.value` 80/20 into `queued` and `dropPot[currentEpoch]`.
- `roll()`: starts or extends the stream. Allowed once the round is over, or mid-round once `queued ≥ minRoll`.
- Balls: `balance × seconds`, booked per user and in total per week on every balance change (one loop step per
  week crossed since the user's last action). `ballsOf(user, week)` and `totalBalls(week)` are views, frozen once the
  week ends.
- `releaseDrop(week)`: only the distributor, only for finished weeks, once. `rollDrop(week)`: anyone, 30 days after
  a week ended, moves an unreleased pot into the current week.
- Owner (timelock): `minRoll` (≤ 1 ETH), stream duration (1–30 days, between rounds), drop share (≤ 30%),
  `setDropDistributor` (once), `recoverERC20` (never the staking token). `launcher`: `setStakingToken`, once.

**`PeggoyDrop.sol`** (the distributor)
1. `settle(week, signature)`: anyone, after the week ends, with drand evmnet's signature for
   `drandRound(week)` = the first round published after the week closed. Verified on chain with randa-mu's BN254
   BLS library (vendored, MIT); ~206k gas on Robinhood Chain. `seed = keccak256(sha256(signature), week)`. Pulls the
   pot from the Machine and freezes `totalBalls`.
2. `enter(week, addresses[])`: for 3 days anyone enters anyone; balls are read from the Machine. Order and
   timing change nothing.
3. Draw: 14 slots, each an independent exponential race: key = −ln(u) / balls with
   `u = keccak256(seed, slot, address)`; lowest key takes the slot. P(win) = balls / total exactly, independent per
   slot, so splitting across wallets changes nothing (tested statistically: 25% of balls → ~25% of slots, split or
   not). No Merkle tree, no off-chain list, no challenge game.
4. `claim(week, slot)` (anyone, pays the winner) / `claimTo` (winner only), 1×40%, 3×10%, 10×3%. After 30 more
   days, `sweep(week)` returns what is left to the Machine (it re-splits 80/20 like any ETH).

If drand halts, nobody can settle, and after 30 days anyone rolls the pot forward. Nothing is ever drawn by hand.

### Status (02 Oct)

| Done | Waiting |
|---|---|
| Machine + Drop written, 41 tests (fuzzed solvency, real drand beacons, win-rate statistics) | Mainnet deploy: Safe 2/3 + funded deployer (launch day) |
| Testnet demo: Machine `0x5B2e…5C2a`, Drop `0x6e8e…9331`; drand verified on Robinhood testnet | Mainnet `setDropDistributor` scheduled by Thu 08 Oct 15:00 UTC |
| Site, Machine page, wallet connect, live at peggoy.fun | External audit before raising expectations |

---

## 4 · Frontend

- **Stack**: static HTML + ES modules, no build step. `three@0.170` (import map, jsDelivr), GSAP 3.12 +
  ScrollTrigger (cdnjs), Lenis (jsDelivr). Same shape as BagyHoody so the same `deploy.sh` ships it.
- **Look**: BagyHoody's engraved-halftone editorial scroll (ink `#0D0B14`, paper `#F1EAD8`) with one accent,
  electric orange `#FF5B14`, plus NIMORI-style game UI: pixel HUD (Press Start 2P / VT323), INSERT COIN boot screen,
  credits counter, 8-bit WebAudio blips.
- **3D**: Meshy models (`cabinet.glb`, `peggoy.glb`) rendered with a halftone shader; the cabinet turns with scroll.
- **Practice board**: 2D canvas pegboard with real ball physics. Click or press Space to drop. Marked "practice
  mode · no wallet · no prize".
- **Sections**: boot → hero (countdown) → manifesto → how to play → practice board → fair-by-construction →
  ETH flow → launch timeline → CTA.

## 5 · Ops

- Host: VPS + nginx (same as BagyHoody), TLS via certbot, `deploy.sh` (build → rsync → reload).
- nginx: CSP, `frame-ancestors 'none'`, `X-Frame-Options DENY`, `Permissions-Policy`. `/rpc` → Node proxy on 127.0.0.1:8787 (ships with the Machine page).
- Keys: deployer key outside the repo; ownership transferred to the Safe in the deploy script; deployer holds no role.
- Launch day: 15:00 UTC create $PEGGOY on Pons → `setStakingToken(CA)` through the Safe (queued 48 h *before* launch with
  a placeholder is not possible, so v1's token setter is the single exception: callable once, by the Safe, before
  the first stake) → `./deploy.sh ca <CA>`.

## 6 · Risks we say out loud

- Unaudited at launch. Caps stay low until the audit.
- The Drop is a prize draw funded by fees; check your local rules.
- drand and Robinhood Chain liveness are external dependencies.

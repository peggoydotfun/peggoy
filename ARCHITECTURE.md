# PEGGOY · architecture

**Drop the ball. Every peg pays.**
A pegboard arcade machine on Robinhood Chain. Stake $PEGGOY, your stake earns *balls* over time, ETH from the
creator tax streams to stakers and a weekly Drop pays out prizes picked by public, verifiable randomness.

Site: **https://peggoy.fun** · Launch: **Fri 03 Oct 2026 · 15:00 UTC** (22:00 WIB · 11:00 ET). $PEGGOY goes live on Pons; the Machine opens on mainnet.

---

## 1 · Concept

| | |
|---|---|
| **Token** | $PEGGOY, launched on Pons (Robinhood Chain, chain id 4663) |
| **Machine** | Single staking contract. Stake $PEGGOY, withdraw anytime, no lock |
| **Balls** | `balls = stake × seconds staked`. Linear, so splitting a stake across 1,000 wallets earns *exactly* the same balls as one wallet |
| **Stream (80%)** | 80% of every ETH that reaches the Machine streams to stakers pro rata over 7 days |
| **Drop (20%)** | 20% builds the weekly Drop. Every Friday 15:00 UTC, winners are drawn weighted by balls earned that week |
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
| 3 | Randomness from an L2 block hash (sequencer can influence it) | **drand** (League of Entropy) round fixed in advance, mixed with the block hash. drand `evmnet` signatures are BN254 and verified on chain |
| 4 | Team picks the snapshot block | The contract fixes the drand round at epoch start: `round = roundAt(epochEnd) + 1`. Nobody chooses it |
| 5 | 24-bit ticket codes collide (~2% at 800 entries) | Winners are addresses. No short codes |
| 6 | `kick()` dust griefing delays real rewards 7 days | `roll()` needs `queued ≥ MIN_ROLL` (0.01 ETH) **or** the period ended; anyone can roll mid-period above the threshold, leftover rolls in |
| 7 | Owner = one EOA, can stretch rewards | Owner = Safe 2-of-3 behind a 48 h timelock. No owner path to stakes or streamed ETH. The Drop distributor is appointed **once** through the timelock (48 h public notice) and can never be swapped; unreleased pots roll forward by anyone after 30 days |
| 8 | `rescueQueued` when totalSupply = 0 | Removed. ETH with no stakers waits in the queue for the first staker |
| 9 | Read API: race → 500, uncached listings, open RPC proxy | No database. Reads: small Node read-only RPC proxy behind nginx: method allowlist, per-IP rate limit, 5 s cache, no batches |
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
                 │      └─ 20% ──▶ DropPot ──▶ epoch close ──▶ DrandVerifier (BN254 BLS)       │
                 │                                   ▲                    │                    │
                 │ Safe 2/3 ──▶ Timelock 48h ──▶ params only          winners claim (pull)    │
                 └───────────────────────────────────┼────────────────────────────────────────┘
                                                     │ signature for round R (anyone can submit)
                                        drand evmnet beacon (public)

 Browser ──▶ peggoy.fun (static, VPS + nginx) ──▶ /rpc (read-only proxy, cached) ──▶ RPC
        └──▶ wallet (EIP-6963): approve, stake, withdraw, claim, roll, settle
```

### Contracts (Foundry, solc 0.8.26)

**`PeggoyMachine.sol`**
- `stake(amount)` / `withdraw(amount)` / `claim()` / `exit()`: balance-delta crediting (taxed tokens), `nonReentrant`.
- `receive()`: splits `msg.value` 80/20 into `queued` and `dropPot[currentEpoch]`.
- `roll()`: starts or extends the stream. Allowed if `block.timestamp ≥ periodFinish` or `queued ≥ MIN_ROLL`.
- Ball accounting: per-epoch `ballsPerToken` accumulator (same maths as `rewardPerToken`), so each user's balls in an
  epoch are `balance × Δaccumulator`. O(1) per action, no loops over users.
- `settle(epoch, drandSig)`: after `epochEnd`, verifies the drand signature for the pre-fixed round, stores
  `seed = keccak256(drandRandomness, blockhash(epochEndBlock))`.
- Winner selection without iterating users: a Merkle sum tree of `(address, balls)` is computed off chain from
  events by a public script and posted by anyone with a bond; it is accepted after a 24 h challenge window unless
  someone proves a wrong leaf (the contract can recompute any single user's balls). Winners = leaves hit by
  `seed`-derived points on the cumulative sum. Prizes are pulled with `claimDrop(epoch, proof)`.
- Unclaimed Drop prizes roll into the next epoch after 30 days.

**`DrandVerifier.sol`**: BN254 pairing check of the drand `evmnet` signature for round `R` (public key pinned at
deploy). Fallback if the beacon halts for 48 h: the epoch's pot rolls into the next one, nothing is drawn by hand.

**Owner surface (Safe → Timelock 48 h):** `MIN_ROLL`, stream duration (1–30 days), Drop share (0–30%).
Not adjustable: the staking token after the first stake, any balance, any pot.

### v1 vs v2 (honest scope for 03 Oct)

| Ships at launch (v1) | Next (v2, before the first Drop on 10 Oct) |
|---|---|
| Machine: stake, withdraw, 80/20 split, Stream, `roll()` with `MIN_ROLL` | `settle()` with the on-chain drand verifier |
| Drop pot accrues on chain, visible on the site | Merkle-sum winner tree + challenge window + `claimDrop` |
| Safe 2/3 + timelock as owner from block 1 | External audit before raising caps |
| Static site, practice-mode board, read proxy | Live board: replay of each real Drop from its seed |

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

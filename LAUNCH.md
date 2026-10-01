# PEGGOY launch runbook

Launch: **Sat 03 Oct 2026 · 15:00 UTC** (22:00 WIB). Site: https://peggoy.fun · X/Telegram: @peggoydotfun

Until launch the Machine page runs the **testnet demo** (free tPEGGOY faucet). At launch it switches to mainnet;
the demo stays at `/machine.html?net=testnet`.

| Testnet demo (46630) | Address |
|---|---|
| Machine | `0x5B2eba6D854F898D59b5f77E7d923085e3475C2a` |
| Timelock 48 h | `0xebA64E8187b941E538420f286BBAA9c1A927f984` |
| tPEGGOY (faucet) | `0xdf7edd050F0af2773C32F955857142995E084e64` |

## Before launch (today / tomorrow)

1. **DNS**: A record `peggoy.fun` (and `www`) → `187.127.98.242`, then `./deploy.sh setup` for TLS.
2. **Safe 2-of-3** on Robinhood Chain: create it on app.safe.global (chain 4663 is supported).
3. **Deployer key** outside the repo (`ops/keys/deployer.key`, gitignored), funded with ~0.001 ETH on mainnet.
4. Deploy the Machine (token not needed yet):
   ```bash
   cd contracts
   SAFE=0x<safe> forge script script/Deploy.s.sol --rpc-url robinhood --broadcast --private-key $(cat ../ops/keys/deployer.key)
   cd .. && ./deploy.sh machine 0x<MACHINE> 0x<TIMELOCK>
   ```

## 15:00 UTC

1. Create **$PEGGOY on Pons**, copy the CA.
2. Set it on the Machine (the deployer is the one-shot launcher):
   ```bash
   cast send 0x<MACHINE> "setStakingToken(address)" 0x<CA> --rpc-url https://rpc.ordofi.network --private-key $(cat ops/keys/deployer.key)
   ```
3. `./deploy.sh ca 0x<CA>`: CA + copy + Buy on Pons go live, the Machine page switches to mainnet.
4. Point the Pons creator-fee recipient at the Machine address, so creator tax flows 80/20 into stream and Drop.

## Before the first Drop (Sat 10 Oct 15:00 UTC)

`PeggoyDrop` is written, tested (real drand beacons) and live on testnet (`0x6e8e3162eAF5e74ea523985CA0AEA8baB6dd9331`).

1. Deploy it on mainnet, pointing at the mainnet Machine:
   ```bash
   cd contracts
   forge create src/PeggoyDrop.sol:PeggoyDrop --rpc-url robinhood --broadcast \
     --private-key $(cat ../ops/keys/deployer.key) --constructor-args 0x<MACHINE>
   ```
   Put its address in `deployments.json → networks.mainnet.drop`, then `./deploy.sh`.
2. From the Safe (app.safe.global → Transaction Builder), call the timelock's `schedule(target, value, data,
   predecessor, salt, delay)` with target = Machine, value = 0, data = `setDropDistributor(<DROP>)` calldata
   (`cast calldata "setDropDistributor(address)" <DROP>`), predecessor = `0x00…00`, any salt, delay = 172800.
   **Do it by Thu 08 Oct 15:00 UTC.** 48 h later, `execute` with the same arguments.
3. After Sat 10 Oct 15:00 UTC: anyone presses **Settle with drand** on the Machine page, entries run 3 days, winners claim.

If it is late, nothing is lost: the pot waits in the Machine, and after 30 days anyone can roll it forward.

### Testnet demo

The distributor appointment is already scheduled on the testnet timelock and becomes executable
**Sat 03 Oct 17:51 UTC**:
```bash
cast send 0xebA64E8187b941E538420f286BBAA9c1A927f984 "execute(address,uint256,bytes,bytes32,bytes32)" \
  0x5B2eba6D854F898D59b5f77E7d923085e3475C2a 0 \
  0x3aa3f1170000000000000000000000006e8e3162eaf5e74ea523985ca0aea8bab6dd9331 \
  0x0000000000000000000000000000000000000000000000000000000000000000 \
  0x92015c96b6c219787ef541dba72af08dee0c87552cbff803eb3d883c73dd757f \
  --rpc-url https://robinhood-sepolia-rpc.publicnode.com --private-key <testnet deployer key>
```

## Emergency

There is no pause by design: withdraw always works. If something is wrong, say so on X/Telegram, stop sending
fees to the Machine, and let stakers exit.

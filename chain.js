// PEGGOY Machine reads and writes without a library.
// Reads: the CORS-enabled public RPC (no proxy of ours to abuse). Writes: the connected wallet, after switching it
// to Robinhood Chain; the page then waits for the receipt and reloads real state.
import * as W from './wallet.js';

const SEL = {
  stakingToken: '0x72f702f3', totalSupply: '0x18160ddd', queued: '0x16049ddf', periodFinish: '0xebe2b12b',
  remainingInPeriod: '0xb5b80f12', rewardRateScaled: '0x8ba732dc', rewardsDuration: '0x386a9525', minRoll: '0xabaafbc2',
  dropBps: '0xd9129498', currentEpoch: '0x76671808', epochEnd: '0xd9be1efe', dropPot: '0xc24aacdb',
  balanceOf: '0x70a08231', earned: '0x008cc262', ballsOf: '0x5bdf4d58', totalBalls: '0xc7b2d850',
  allowance: '0xdd62ed3e', decimals: '0x313ce567', symbol: '0x95d89b41',
  approve: '0x095ea7b3', faucet: '0xde5f72fd',
  drandRound: '0xaa694896', draws: '0x0cc36c36', settle: '0x39c2ebb9', enter: '0x8ecee083', winner: '0xb47deb3c',
  paid: '0x8d42394d', entered: '0x4d333814', claimSlot: '0xc3490263', dropDistributor: '0x0ca86d3a', stake: '0xa694fc3a', withdraw: '0x2e1a7d4d', claim: '0x4e71d92d', exit: '0xe9fad8ee', roll: '0xcd5e3c5d',
};
const word = (v) => BigInt(v).toString(16).padStart(64, '0');
const addrWord = (a) => a.toLowerCase().replace(/^0x/, '').padStart(64, '0');
const enc = (sel, ...args) => sel + args.map((a) => (typeof a === 'string' && /^0x[0-9a-fA-F]{40}$/.test(a) ? addrWord(a) : word(a))).join('');
const ZERO = '0x0000000000000000000000000000000000000000';

let cfg = null, rpcId = 0;
/// Active network from deployments.json; `?net=testnet|mainnet` overrides it (the demo stays reachable after launch).
export async function config() {
  if (cfg) return cfg;
  const all = await fetch('deployments.json', { cache: 'no-store' }).then((r) => r.json());
  const want = new URLSearchParams(location.search).get('net');
  const net = all.networks[want] ? want : all.active;
  cfg = { ...all.networks[net], net, active: all.active };
  return cfg;
}

async function rpc(method, params) {
  const c = await config();
  let err;
  for (const url of [c.rpc, c.rpcFallback].filter(Boolean)) { // public RPC, then a second provider
    try {
      const r = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: ++rpcId, method, params }) });
      const j = await r.json();
      if (j.error) throw new Error(j.error.message || 'RPC error');
      return j.result;
    } catch (e) { err = e; }
  }
  // last resort: the connected wallet's own RPC when it is on the right chain
  const acc = W.account();
  if (acc && acc.chainId === c.chainId) return acc.provider.request({ method, params });
  throw err;
}
const call = (to, data) => rpc('eth_call', [{ to, data }, 'latest']);
const uint = async (to, data) => BigInt(await call(to, data));

/// Everything the Machine page shows, read off the chain. `user` is optional.
export async function machineState(user) {
  const c = await config();
  const M = c.machine;
  if (!/^0x[0-9a-fA-F]{40}$/.test(M)) return { deployed: false };
  const [tokenRaw, staked, queued, finish, remaining, rate, duration, minRoll, dropBps, epoch] = await Promise.all([
    call(M, SEL.stakingToken), uint(M, SEL.totalSupply), uint(M, SEL.queued), uint(M, SEL.periodFinish),
    uint(M, SEL.remainingInPeriod), uint(M, SEL.rewardRateScaled), uint(M, SEL.rewardsDuration), uint(M, SEL.minRoll),
    uint(M, SEL.dropBps), uint(M, SEL.currentEpoch),
  ]);
  const token = '0x' + tokenRaw.slice(-40);
  const s = {
    deployed: true, machine: M, token: token === ZERO ? null : token, staked, queued, finish: Number(finish), remaining,
    rate, duration: Number(duration), minRoll, dropBps: Number(dropBps), epoch, decimals: 18, symbol: 'PEGGOY', user: null,
  };
  const [pot, epochEnd, totalBalls] = await Promise.all([uint(M, enc(SEL.dropPot, epoch)), uint(M, enc(SEL.epochEnd, epoch)), uint(M, enc(SEL.totalBalls, epoch))]);
  Object.assign(s, { pot, epochEnd: Number(epochEnd), totalBalls });
  if (s.token) s.decimals = Number(await uint(s.token, SEL.decimals));
  if (user) {
    const [mine, earned, balls] = await Promise.all([uint(M, enc(SEL.balanceOf, user)), uint(M, enc(SEL.earned, user)), uint(M, enc(SEL.ballsOf, user, epoch))]);
    s.user = { mine, earned, balls, wallet: 0n, allowance: 0n };
    if (s.token) [s.user.wallet, s.user.allowance] = await Promise.all([uint(s.token, enc(SEL.balanceOf, user)), uint(s.token, enc(SEL.allowance, user, M))]);
  }
  return s;
}

/// Last finished week's draw on the PeggoyDrop contract (null when no Drop contract is configured).
export async function dropState(week, user) {
  const c = await config();
  const D = c.drop;
  if (!/^0x[0-9a-fA-F]{40}$/.test(D || '') || week < 0n) return null;
  const [distRaw, roundRaw, drawRaw, potRaw] = await Promise.all([
    call(c.machine, SEL.dropDistributor), call(D, enc(SEL.drandRound, week)), call(D, enc(SEL.draws, week)), call(c.machine, enc(SEL.dropPot, week)),
  ]);
  const w = (i) => BigInt('0x' + drawRaw.slice(2 + i * 64, 2 + (i + 1) * 64));
  const st = {
    drop: D, week, appointed: ('0x' + distRaw.slice(-40)).toLowerCase() === D.toLowerCase(), round: Number(BigInt(roundRaw)),
    seed: '0x' + drawRaw.slice(2, 66), settledAt: Number(w(2)), pot: w(3), totalBalls: w(4), paidOut: w(5), swept: w(6) === 1n,
    potInMachine: BigInt(potRaw), slots: [], entered: false,
  };
  if (st.settledAt) {
    const idx = [...Array(14).keys()];
    const [winners, paid] = await Promise.all([
      Promise.all(idx.map((i) => call(D, enc(SEL.winner, week, i)))), Promise.all(idx.map((i) => uint(D, enc(SEL.paid, week, i)))),
    ]);
    st.slots = idx.map((i) => ({ slot: i, winner: '0x' + winners[i].slice(-40), paid: paid[i] === 1n, bps: i === 0 ? 4000 : i < 4 ? 1000 : 300 }));
    if (user) st.entered = (await uint(D, enc(SEL.entered, week, user))) === 1n;
  }
  return st;
}

/// The drand evmnet signature for `round`, from the public API (anyone could fetch it from any drand relay).
export async function drandSignature(round) {
  const r = await fetch(`https://api.drand.sh/v2/beacons/evmnet/rounds/${round}`);
  if (!r.ok) throw new Error('drand round ' + round + ' is not published yet.');
  const j = await r.json();
  if (!/^[0-9a-f]{128}$/.test(j.signature || '')) throw new Error('Unexpected drand response.');
  return j.signature;
}

async function send(to, data) {
  const c = await config();
  const acc = W.account();
  if (!acc) throw new Error('Connect a wallet first.');
  await W.ensureChain(c);
  // our own estimate + 30%: storage refunds (withdraw/exit) make tight estimates run out of gas in some wallets
  const tx = { from: acc.address, to, data };
  try {
    const est = BigInt(await acc.provider.request({ method: 'eth_estimateGas', params: [tx] }));
    tx.gas = '0x' + ((est * 13n) / 10n).toString(16);
  } catch { /* let the wallet estimate; a real revert shows up there with its reason */ }
  const hash = await acc.provider.request({ method: 'eth_sendTransaction', params: [tx] });
  for (let i = 0; i < 90; i++) {
    const r = await rpc('eth_getTransactionReceipt', [hash]).catch(() => null);
    if (r) { if (r.status !== '0x1') throw new Error('Transaction reverted.'); return hash; }
    await new Promise((res) => setTimeout(res, 1500));
  }
  return hash; // sent, not seen yet: the next refresh catches up
}

export const tx = {
  approve: (token, spender, amount) => send(token, enc(SEL.approve, spender, amount)),
  stake: (m, amount) => send(m, enc(SEL.stake, amount)),
  withdraw: (m, amount) => send(m, enc(SEL.withdraw, amount)),
  claim: (m) => send(m, SEL.claim),
  exit: (m) => send(m, SEL.exit),
  roll: (m) => send(m, SEL.roll),
  faucet: (token) => send(token, SEL.faucet), // testnet demo token only
  // PeggoyDrop: settle(uint256,bytes) and enter(uint256,address[]) carry dynamic args, encoded by hand
  settle: (drop, week, sigHex) => send(drop, SEL.settle + word(week) + word(0x40) + word(64) + sigHex),
  enter: (drop, week, user) => send(drop, SEL.enter + word(week) + word(0x40) + word(1) + addrWord(user)),
  claimSlot: (drop, week, slot) => send(drop, enc(SEL.claimSlot, week, slot)),
};

// ---------- amounts ----------
export function units(str, decimals) {
  const s = String(str).trim().replace(/,/g, '');
  if (!/^\d*(\.\d*)?$/.test(s) || s === '' || s === '.') throw new Error('Enter a number.');
  const [i, f = ''] = s.split('.');
  return BigInt(i || '0') * 10n ** BigInt(decimals) + BigInt((f + '0'.repeat(decimals)).slice(0, decimals) || '0');
}
export function fmt(v, decimals = 18, shown = 4) {
  const base = 10n ** BigInt(decimals);
  const i = v / base;
  const f = (v % base).toString().padStart(decimals, '0').slice(0, shown).replace(/0+$/, '');
  return i.toLocaleString('en-US') + (f ? '.' + f : '');
}

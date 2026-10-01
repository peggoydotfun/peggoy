// The Machine page: stake / withdraw / claim / exit / roll, all numbers read off the chain.
import * as W from './wallet.js';
import * as C from './chain.js';
import { initConnect, openPicker, toast } from './connect-ui.js';
import { sfx, unlock, isMuted, setMuted } from './sound.js';

const $ = (s, r = document) => r.querySelector(s);
const esc = W.esc;
const ST = { s: null, d: null, err: '', busy: '', msg: '', amount: '', cfg: null };
const now = () => Date.now() / 1000;
const kv = (k, v, cls = '') => `<div class="kv ${cls}"><span>${k}</span><i></i><b>${v}</b></div>`;
const eth = (v) => C.fmt(v, 18, 5) + ' ETH';
const tok = (v) => C.fmt(v, ST.s?.decimals ?? 18, 2);
const link = (addr) => `<a href="${ST.cfg.explorer}/address/${addr}" target="_blank" rel="noopener">${W.short(addr)} ↗</a>`;
const when = (ts) => new Date(ts * 1000).toUTCString().slice(5, 22) + ' UTC';
function left(ts) {
  const s = Math.max(0, Math.floor(ts - now()));
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
  return d ? `${d}d ${h}h ${m}m` : `${h}h ${m}m ${s % 60}s`;
}

async function load() {
  try {
    ST.cfg = await C.config();
    ST.s = await C.machineState(W.account()?.address);
    ST.d = ST.s.deployed ? await C.dropState(ST.s.epoch - 1n, W.account()?.address).catch(() => null) : null;
    ST.err = '';
  } catch (e) {
    ST.err = 'Could not read the chain. Retrying…';
  }
  if (!document.activeElement?.matches?.('[data-amount]')) render();
  else renderStats();
}

function status() {
  const s = ST.s, c = ST.cfg;
  if (!s) return 'READING CHAIN…';
  if (c.demo) return 'TESTNET DEMO · TOKENS HAVE NO VALUE · MAINNET OPENS 03 OCT 15:00 UTC';
  if (!s.deployed) return `OPENS ${new Date(c.genesis * 1000).toUTCString().slice(5, 16).toUpperCase()} · 15:00 UTC`;
  if (!s.token) return 'DEPLOYED · TOKEN IS SET AT LAUNCH';
  return 'LIVE · ROBINHOOD CHAIN';
}

function seat() {
  const s = ST.s, acc = W.account(), busy = !!ST.busy;
  const note = `${ST.busy ? `<p class="note">${esc(ST.busy)}… CHECK YOUR WALLET</p>` : ''}${ST.msg ? `<p class="note ${/done/i.test(ST.msg) ? 'ok' : 'warn'}">${esc(ST.msg)}</p>` : ''}`;
  if (!s?.deployed || !s.token) {
    return `<p class="lead">The Machine opens when $PEGGOY launches on Pons.</p>
      ${kv('LAUNCH', when(ST.cfg?.genesis ?? 0))}
      ${acc ? kv('WALLET', esc(W.short(acc.address))) : `<button class="gb gb--go" type="button" data-wconnect>▶ CONNECT WALLET</button>`}
      <p class="small muted">Connect now: your seat appears here the moment the Machine opens.</p>`;
  }
  if (!acc) return `<p class="lead">Stake $PEGGOY, earn ETH and balls. Withdraw anytime.</p><button class="gb gb--go" type="button" data-wconnect>▶ CONNECT WALLET</button>${note}`;
  if (acc.chainId !== ST.cfg.chainId) return `<p class="lead">Your wallet is on another network.</p><button class="gb gb--go" type="button" data-switch>▶ SWITCH TO ROBINHOOD CHAIN</button>${note}`;
  const u = s.user;
  if (!u) return '<p class="lead">Reading your seat…</p>';
  const demo = ST.cfg.demo ? `<div class="demo">
      <p><b>Demo on Robinhood Chain testnet.</b> Grab free tPEGGOY, then stake, roll and claim like on launch day.</p>
      <button class="gb gb--go" type="button" data-act="faucet" ${busy ? 'disabled' : ''}>▶ GET 10,000 tPEGGOY</button>
      <p class="small">Need testnet ETH for gas? ${ST.cfg.faucets.map((f, i) => `<a href="${f}" target="_blank" rel="noopener">faucet ${i + 1} ↗</a>`).join(' · ')}</p>
    </div>` : '';
  const share = s.totalBalls > 0n ? Number((u.balls * 1_000_000n) / s.totalBalls) / 10_000 : 0;
  const needsApprove = (() => { try { return u.allowance < C.units(ST.amount || '0', s.decimals) || u.allowance === 0n; } catch { return u.allowance === 0n; } })();
  const sym = ST.cfg.demo ? 'tPEGGOY' : 'PEGGOY';
  return `${demo}
    ${kv('WALLET', tok(u.wallet) + ' ' + sym)}
    ${kv('STAKED', tok(u.mine) + ' ' + sym)}
    ${kv('EARNED', eth(u.earned), 'hot')}
    ${kv('BALLS THIS WEEK', share.toFixed(2) + '% of all')}
    <div class="amount">
      <input data-amount inputmode="decimal" autocomplete="off" placeholder="0.0" aria-label="Amount of PEGGOY" value="${esc(ST.amount)}" ${busy ? 'disabled' : ''}>
      <button class="gb" type="button" data-max="wallet" ${busy ? 'disabled' : ''}>MAX</button>
    </div>
    <div class="actions">
      <button class="gb gb--go" type="button" data-act="stake" ${busy ? 'disabled' : ''}>${needsApprove ? '▶ APPROVE + STAKE' : '▶ STAKE'}</button>
      <button class="gb" type="button" data-act="withdraw" ${busy || !u.mine ? 'disabled' : ''}>WITHDRAW</button>
      <button class="gb" type="button" data-act="claim" ${busy || !u.earned ? 'disabled' : ''}>CLAIM ETH</button>
      <button class="gb" type="button" data-act="exit" ${busy || !u.mine ? 'disabled' : ''}>EXIT ALL</button>
    </div>
    <p class="small muted">First stake asks for 2 transactions: approve, then stake. Withdraw has no lock and no fee.</p>
    ${note}`;
}

function stream() {
  const s = ST.s;
  if (!s?.deployed) return '<p class="muted">Not deployed yet.</p>';
  const perDay = s.remaining > 0n ? (s.rate * 86400n) / 10n ** 18n : 0n;
  const canRoll = s.token && s.queued > 0n && (s.finish <= now() || s.queued >= s.minRoll);
  return `
    ${kv('TOTAL STAKED', s.token ? tok(s.staked) + ' PEGGOY' : '—')}
    ${kv('STREAMING', s.remaining > 0n ? eth(perDay) + ' / day' : 'IDLE')}
    ${kv('LEFT THIS ROUND', eth(s.remaining))}
    ${kv('ROUND ENDS', s.finish > now() ? `<span data-left="${s.finish}">${left(s.finish)}</span>` : '—')}
    ${kv('QUEUED NEXT', eth(s.queued))}
    <p class="small muted">ETH waits in the queue, then streams over ${Math.round(s.duration / 86400)} days. Anyone can start the next round when one ends, or mid-round once ${eth(s.minRoll)} is queued.</p>
    ${canRoll ? `<button class="gb gb--go" type="button" data-act="roll" ${ST.busy ? 'disabled' : ''}>▶ ROLL QUEUED ETH IN</button>` : ''}`;
}

function drop() {
  const s = ST.s;
  if (!s?.deployed) return `<p class="muted">First Drop: Sat 10 Oct · 15:00 UTC.</p>`;
  return `
    ${kv('WEEK', '#' + s.epoch.toString())}
    ${kv('POT', eth(s.pot), 'hot')}
    ${kv('DRAW IN', `<span data-left="${s.epochEnd}">${left(s.epochEnd)}</span>`)}
    ${kv('SLOTS', '1×40% · 3×10% · 10×3%')}
    <p class="small muted">Winners are drawn by balls (stake × seconds) from a drand round fixed when the week starts. Splitting your stake across wallets does not change your odds.</p>`;
}

function draw() {
  const s = ST.s, d = ST.d, acc = W.account(), busy = ST.busy ? 'disabled' : '';
  if (!s?.deployed || s.epoch === 0n) return `<p class="muted">The first draw runs when week #0 closes.</p>`;
  if (!d) return '<p class="muted">Draw contract not configured.</p>';
  const head = kv('WEEK', '#' + d.week.toString()) + kv('DRAND ROUND', '#' + d.round);
  if (!d.settledAt) {
    if (!d.appointed) return `${head}${kv('POT WAITING', eth(d.potInMachine))}<p class="small muted">The draw contract is being appointed through the 48 h timelock. The pot waits safely in the Machine.</p>`;
    return `${head}${kv('POT', eth(d.potInMachine), 'hot')}
      <p class="small muted">The week is closed. Anyone can settle it with drand round #${d.round}: the page fetches the signature and the contract verifies it.</p>
      <button class="gb gb--go" type="button" data-act="settle" ${busy}>▶ SETTLE WITH DRAND</button>`;
  }
  const entryEnds = d.settledAt + 3 * 86400;
  const open = now() < entryEnds;
  const me = acc?.address.toLowerCase();
  const rows = d.slots.map((x) => {
    const mine = me && x.winner.toLowerCase() === me;
    const amt = (d.pot * BigInt(x.bps)) / 10000n;
    const who = /^0x0{40}$/.test(x.winner) ? '—' : mine ? 'YOU' : W.short(x.winner);
    const act = mine && !open && !x.paid && !d.swept ? `<button class="gb gb--go gb--mini" type="button" data-claim="${x.slot}" ${busy}>CLAIM</button>` : x.paid ? '<em>PAID</em>' : '';
    return `<tr class="${mine ? 'is-mine' : ''}"><td>#${x.slot + 1}</td><td>${x.bps / 100}%</td><td>${C.fmt(amt, 18, 5)}</td><td>${who}</td><td>${act}</td></tr>`;
  }).join('');
  const enterBtn = open && acc && !d.entered ? `<button class="gb gb--go" type="button" data-act="enter" ${busy}>▶ ENTER MY WALLET</button>` : '';
  return `${head}${kv('POT', eth(d.pot), 'hot')}
    ${kv(open ? 'ENTRIES CLOSE IN' : 'ENTRIES', open ? `<span data-left="${entryEnds}">${left(entryEnds)}</span>` : 'CLOSED')}
    ${open ? `<p class="small muted">${d.entered ? 'Your wallet is entered.' : 'Enter your wallet (free, one transaction) or anyone can enter it for you. Order and timing change nothing.'}</p>` : ''}
    ${enterBtn}
    <table class="slots-table"><thead><tr><th>SLOT</th><th>SHARE</th><th>ETH</th><th>${open ? 'LEADING' : 'WINNER'}</th><th></th></tr></thead><tbody>${rows}</tbody></table>
    <p class="small muted">Seed ${d.seed.slice(0, 10)}… from drand round #${d.round}. Re-run it: keyFor(seed, slot, address, balls) on the contract.</p>`;
}

function contracts() {
  const s = ST.s, c = ST.cfg;
  if (!c) return '';
  const row = (k, a) => kv(k, /^0x[0-9a-fA-F]{40}$/.test(a || '') ? link(a) : 'AT LAUNCH');
  return `${kv('NETWORK', c.demo ? 'TESTNET (DEMO)' : 'MAINNET')}${row('MACHINE', c.machine)}${row('DROP', c.drop)}${row('TIMELOCK 48H', c.timelock)}${row(c.demo ? 'tPEGGOY' : '$PEGGOY', s?.token || c.token)}
    ${c.net !== c.active ? '' : c.demo ? '<p class="small"><a href="?net=mainnet">Mainnet view ↗</a></p>' : '<p class="small"><a href="?net=testnet">Try the testnet demo ↗</a></p>'}
    <p class="small muted">${c.demo ? 'Testnet demo: same contract and 48 h timelock as mainnet; here the timelock is run by the deployer instead of the Safe.' : 'Owner is a 2-of-3 Safe behind a 48 h timelock. It can tune bounded numbers, never touch stakes or streamed ETH.'}</p>`;
}

// Write a panel only when its markup changed, so buttons are not swapped under the user's cursor.
const put = (sel, html) => { const el = $(sel); if (el._html !== html) { el.innerHTML = html; el._html = html; } };
function renderStats() {
  $('#status').textContent = ST.err || status();
  put('#stream', stream());
  put('#drop', drop());
  put('#draw', draw());
  put('#contracts', contracts());
}
function render() {
  renderStats();
  put('#seat', seat());
}

// ---------- actions ----------
async function run(label, fn) {
  if (!W.account()) return openPicker();
  ST.busy = label; ST.msg = ''; render();
  try { await fn(); ST.msg = label + ' done.'; sfx('score', true); }
  catch (e) { ST.msg = (e?.code === 4001 || /reject|denied/i.test(e?.message) ? 'Rejected in your wallet.' : (e?.shortMessage || e?.message || 'Failed.')).slice(0, 160); sfx('drop'); }
  ST.busy = ''; await load();
}
function amount() {
  const v = $('[data-amount]')?.value ?? ST.amount;
  ST.amount = v;
  const a = C.units(v, ST.s.decimals);
  if (a <= 0n) throw new Error('Enter an amount.');
  return a;
}
const ACT = {
  async stake() {
    let a; try { a = amount(); } catch (e) { ST.msg = e.message; return render(); }
    if (a > ST.s.user.wallet) { ST.msg = 'More than your wallet holds.'; return render(); }
    await run('STAKE', async () => {
      if (ST.s.user.allowance < a) { ST.busy = 'APPROVE (1/2)'; render(); await C.tx.approve(ST.s.token, ST.s.machine, a); ST.busy = 'STAKE (2/2)'; render(); }
      await C.tx.stake(ST.s.machine, a);
      ST.amount = '';
    });
  },
  async withdraw() {
    let a; try { a = amount(); } catch (e) { ST.msg = e.message; return render(); }
    if (a > ST.s.user.mine) { ST.msg = 'More than you staked.'; return render(); }
    await run('WITHDRAW', async () => { await C.tx.withdraw(ST.s.machine, a); ST.amount = ''; });
  },
  claim: () => run('CLAIM', () => C.tx.claim(ST.s.machine)),
  exit: () => run('EXIT', () => C.tx.exit(ST.s.machine)),
  roll: () => run('ROLL', () => C.tx.roll(ST.s.machine)),
  faucet: () => run('FAUCET', () => C.tx.faucet(ST.s.token)),
  settle: () => run('SETTLE', async () => { const sig = await C.drandSignature(ST.d.round); await C.tx.settle(ST.d.drop, ST.d.week, sig); }),
  enter: () => run('ENTER', () => C.tx.enter(ST.d.drop, ST.d.week, W.account().address)),
};

document.addEventListener('click', (e) => {
  const b = e.target.closest('button');
  if (!b || b.disabled) return;
  if (b.matches('[data-wconnect]')) openPicker();
  else if (b.matches('[data-switch]')) W.ensureChain(ST.cfg).then(load).catch((err) => toast(String(err?.message || err)));
  else if (b.matches('[data-max]')) {
    const u = ST.s?.user; if (!u) return;
    ST.amount = C.fmt(u.wallet > 0n ? u.wallet : u.mine, ST.s.decimals, ST.s.decimals).replace(/,/g, '');
    render();
  } else if (b.dataset.claim) run('CLAIM SLOT', () => C.tx.claimSlot(ST.d.drop, ST.d.week, +b.dataset.claim));
  else if (b.dataset.act) ACT[b.dataset.act]?.();
});
document.addEventListener('input', (e) => { if (e.target.matches('[data-amount]')) ST.amount = e.target.value; });

// ---------- sound toggle ----------
const muteBtn = $('#mute');
const paintMute = () => {
  muteBtn.setAttribute('aria-pressed', String(!isMuted()));
  muteBtn.innerHTML = isMuted()
    ? '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M11 5 6 9H3v6h3l5 4zM22 9l-6 6M16 9l6 6"/></svg>'
    : '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M11 5 6 9H3v6h3l5 4zM15.5 8.5a5 5 0 0 1 0 7M18.5 5.5a9 9 0 0 1 0 13"/></svg>';
};
muteBtn.addEventListener('click', () => { setMuted(!isMuted()); paintMute(); unlock(); sfx('coin'); });
paintMute();
addEventListener('pointerdown', unlock, { once: true });

initConnect({ machineHref: null });
W.onChange(() => load());
load();
setInterval(() => { if (!document.hidden && !ST.busy) load(); }, 15000);
// countdowns tick in place; nothing else re-renders every second
setInterval(() => document.querySelectorAll('[data-left]').forEach((el) => (el.textContent = left(+el.dataset.left))), 1000);

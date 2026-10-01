// Topbar "Connect wallet" button + retro wallet picker, shared by the landing page and the Machine page.
import * as W from './wallet.js';
import { sfx } from './sound.js';

const $ = (s, r = document) => r.querySelector(s);

function modal() {
  let m = $('#walletModal');
  if (m) return m;
  m = document.createElement('div');
  m.id = 'walletModal';
  m.className = 'modal';
  m.hidden = true;
  m.innerHTML = '<div class="modal__card" role="dialog" aria-modal="true" aria-labelledby="wmTitle"></div>';
  document.body.append(m);
  m.addEventListener('click', (e) => { if (e.target === m) close(); });
  addEventListener('keydown', (e) => { if (e.key === 'Escape' && !m.hidden) close(); });
  return m;
}
let lastFocus = null;
function close() { const m = modal(); m.hidden = true; lastFocus?.focus?.(); }

export function openPicker() {
  const m = modal(), card = $('.modal__card', m), list = W.wallets();
  lastFocus = document.activeElement;
  card.innerHTML = `
    <div class="modal__head"><span class="px">PLAYER SELECT</span><h2 id="wmTitle">Connect wallet</h2></div>
    <p class="modal__text">${list.length ? 'Pick a wallet. Connecting only reads your address. Every transaction is shown in your wallet before it is sent.' : 'No wallet found in this browser. Install one (Rabby, MetaMask, Coinbase Wallet) or open this page in your wallet app.'}</p>
    <div class="wallets">${list.map((w, i) => `<button type="button" class="wallet-opt" data-wpick="${i}">${w.icon ? `<img src="${w.icon}" alt="" width="28" height="28">` : '<i class="wallet-opt__ph"></i>'}<span>${W.esc(w.name)}</span><small>DETECTED</small></button>`).join('')}</div>
    <p class="modal__note">PEGGOY never asks for a seed phrase and never DMs first.</p>
    <button type="button" class="gb modal__close" data-wclose>CLOSE</button>`;
  m.hidden = false;
  sfx('coin');
  card.querySelectorAll('[data-wpick]').forEach((b) => b.addEventListener('click', async () => {
    const w = list[+b.dataset.wpick];
    close();
    try { await W.connect(w); sfx('start'); } catch (err) { toast(/reject|denied|4001/i.test(String(err?.message)) ? 'Connection cancelled.' : String(err?.message || err)); }
  }));
  $('[data-wclose]', card).addEventListener('click', close);
  ($('[data-wpick]', card) || $('[data-wclose]', card)).focus();
}

export function toast(msg) {
  let t = $('#toast');
  if (!t) { t = document.createElement('div'); t.id = 'toast'; t.className = 'toast'; t.setAttribute('role', 'status'); document.body.append(t); }
  t.textContent = msg;
  t.classList.add('is-on');
  clearTimeout(toast._t);
  toast._t = setTimeout(() => t.classList.remove('is-on'), 3200);
}

/// Wires every [data-connect] button: connect when disconnected, menu (machine / disconnect) when connected.
export function initConnect({ machineHref = 'machine.html' } = {}) {
  const paint = () => {
    const a = W.account();
    document.querySelectorAll('[data-connect]').forEach((b) => {
      b.textContent = a ? W.short(a.address) : 'Connect wallet';
      b.classList.toggle('is-connected', !!a);
      b.title = a ? `${a.name} · click to disconnect` : 'Connect a wallet';
    });
  };
  document.querySelectorAll('[data-connect]').forEach((b) => b.addEventListener('click', () => {
    if (!W.account()) return openPicker();
    if (machineHref && !location.pathname.includes('machine')) { location.href = machineHref; return; }
    W.disconnect(); toast('Wallet disconnected.');
  }));
  W.onChange(paint);
  paint();
  W.restore();
}

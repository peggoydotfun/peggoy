// Docs page: wallet button + the contracts table, filled from deployments.json (one source of truth).
import { initConnect } from './connect-ui.js';
import { esc } from './wallet.js';

initConnect();

const isAddr = (a) => /^0x[0-9a-fA-F]{40}$/.test(a || '');
const cell = (net, a) => (isAddr(a)
  ? `<a href="${esc(net.explorer)}/address/${a}" target="_blank" rel="noopener"><code>${a.slice(0, 6)}…${a.slice(-4)}</code> ↗</a>`
  : '<span class="muted">at launch</span>');

fetch('deployments.json', { cache: 'no-store' }).then((r) => r.json()).then(({ networks: { mainnet: m, testnet: t } }) => {
  const rows = [
    ['PeggoyMachine', 'machine'], ['PeggoyDrop', 'drop'], ['Timelock (48 h)', 'timelock'], ['Token', 'token'],
  ].map(([label, k]) => `<tr><td>${label}${k === 'token' ? ' <span class="muted">($PEGGOY / tPEGGOY)</span>' : ''}</td><td>${cell(m, m[k])}</td><td>${cell(t, t[k])}</td></tr>`);
  document.querySelector('#addr tbody').innerHTML = rows.join('');
}).catch(() => { document.querySelector('#addr tbody').innerHTML = '<tr><td colspan="3">Could not load addresses.</td></tr>'; });

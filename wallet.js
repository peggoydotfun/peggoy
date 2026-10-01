// Wallet connection without a library: EIP-6963 discovery, window.ethereum as a fallback.
// Fixes from the NIMORI review: one listener set per provider (removed on disconnect, so a stale wallet can
// never resurrect a half-connected account), injected names escaped, icons accepted only as data:image/.
const found = new Map(); // rdns -> { info, provider }
addEventListener('eip6963:announceProvider', (e) => {
  const d = e.detail;
  if (d?.info?.rdns && d.provider) found.set(d.info.rdns, d);
});
dispatchEvent(new Event('eip6963:requestProvider'));

const STORE_KEY = 'peggoy-wallet';
let current = null; // { provider, address, name, chainId }
let detach = null;
const listeners = new Set();
const emit = () => listeners.forEach((f) => f(current));

export const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const safeIcon = (u) => (typeof u === 'string' && /^data:image\/(png|svg\+xml|webp|jpeg|gif);/.test(u) ? u : '');

export function wallets() {
  const list = [...found.values()].map((d) => ({ id: d.info.rdns, name: String(d.info.name || 'Wallet').slice(0, 40), icon: safeIcon(d.info.icon), provider: d.provider }));
  if (!list.length && window.ethereum) list.push({ id: 'injected', name: 'Browser wallet', icon: '', provider: window.ethereum });
  return list;
}
export const account = () => current;
export const onChange = (f) => { listeners.add(f); return () => listeners.delete(f); };
export const short = (a) => (a ? a.slice(0, 6) + '…' + a.slice(-4) : '');

function attach(provider) {
  const onAccounts = (a) => {
    if (!current || current.provider !== provider) return;
    if (a && a[0]) current = { ...current, address: a[0] };
    else return disconnect();
    emit();
  };
  const onChain = (id) => { if (current?.provider === provider) { current = { ...current, chainId: parseInt(id, 16) }; emit(); } };
  const onDisconnect = () => { if (current?.provider === provider) disconnect(); };
  provider.on?.('accountsChanged', onAccounts);
  provider.on?.('chainChanged', onChain);
  provider.on?.('disconnect', onDisconnect);
  return () => {
    provider.removeListener?.('accountsChanged', onAccounts);
    provider.removeListener?.('chainChanged', onChain);
    provider.removeListener?.('disconnect', onDisconnect);
  };
}

export async function connect(w, { silent = false } = {}) {
  const accs = await w.provider.request({ method: silent ? 'eth_accounts' : 'eth_requestAccounts' });
  if (!accs || !accs[0]) { if (silent) return null; throw new Error('No account returned by the wallet.'); }
  detach?.();
  const chainId = parseInt(await w.provider.request({ method: 'eth_chainId' }), 16);
  current = { provider: w.provider, address: accs[0], name: w.name, chainId };
  detach = attach(w.provider);
  try { localStorage.setItem(STORE_KEY, w.id); } catch { /* ignore */ }
  emit();
  return current;
}

export function disconnect() {
  detach?.(); detach = null;
  current = null;
  try { localStorage.removeItem(STORE_KEY); } catch { /* ignore */ }
  emit();
}

/// Reconnects silently (eth_accounts, no popup) to the wallet used last time, if it still grants access.
export async function restore() {
  let id = null;
  try { id = localStorage.getItem(STORE_KEY); } catch { /* ignore */ }
  if (!id) return null;
  await new Promise((r) => setTimeout(r, 150)); // let EIP-6963 wallets announce themselves
  const w = wallets().find((x) => x.id === id);
  return w ? connect(w, { silent: true }).catch(() => null) : null;
}

export async function ensureChain(cfg) {
  const p = current?.provider;
  if (!p) throw new Error('Connect a wallet first.');
  const hex = '0x' + cfg.chainId.toString(16);
  if ((await p.request({ method: 'eth_chainId' })) === hex) return;
  try {
    await p.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: hex }] });
  } catch (e) {
    if (e?.code !== 4902) throw e;
    await p.request({ method: 'wallet_addEthereumChain', params: [{
      chainId: hex, chainName: cfg.chainName, nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
      rpcUrls: [cfg.walletRpc], blockExplorerUrls: [cfg.explorer],
    }] });
  }
}

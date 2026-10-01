// 8-bit blips synthesised with WebAudio. No audio files. The context starts on the first user gesture.
let ac = null, master = null, muted = false;
try { muted = localStorage.getItem('peggoy-muted') === '1'; } catch { /* storage blocked: sound stays on */ }

function ctx() {
  if (!ac) {
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return null;
    ac = new AC();
    master = ac.createGain(); master.gain.value = 0.18; master.connect(ac.destination);
  }
  if (ac.state === 'suspended') ac.resume();
  return ac;
}

function tone(freq, dur, { type = 'square', at = 0, vol = 1, slide = 0 } = {}) {
  const a = ctx(); if (!a) return;
  const t0 = a.currentTime + at;
  const o = a.createOscillator(), g = a.createGain();
  o.type = type; o.frequency.setValueAtTime(freq, t0);
  if (slide) o.frequency.exponentialRampToValueAtTime(freq * slide, t0 + dur);
  g.gain.setValueAtTime(vol, t0); g.gain.exponentialRampToValueAtTime(0.0001, t0 + dur);
  o.connect(g); g.connect(master); o.start(t0); o.stop(t0 + dur + 0.02);
}

const FX = {
  peg: () => tone(1400 + Math.random() * 600, 0.03, { vol: 0.25 }),
  drop: () => tone(520, 0.08, { slide: 0.5, vol: 0.6 }),
  score: (big) => (big ? [523, 659, 784, 1047, 1319] : [659, 988]).forEach((f, i) => tone(f, 0.09, { at: i * 0.07, vol: 0.55 })),
  coin: () => { tone(988, 0.06, { vol: 0.6 }); tone(1319, 0.18, { at: 0.06, vol: 0.6 }); },
  start: () => [392, 523, 659, 784].forEach((f, i) => tone(f, 0.1, { at: i * 0.08, type: 'triangle', vol: 0.8 })),
};

let lastPeg = 0;
export function sfx(name, arg) {
  if (muted || !ac && name === 'peg') return;
  if (name === 'peg') { const n = performance.now(); if (n - lastPeg < 45) return; lastPeg = n; }
  FX[name]?.(arg);
}
export const unlock = () => ctx();
export const isMuted = () => muted;
export function setMuted(m) {
  muted = m;
  try { localStorage.setItem('peggoy-muted', m ? '1' : '0'); } catch { /* ignore */ }
}

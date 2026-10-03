// PEGGOY landing: boot screen, smooth scroll, countdown, practice board, and one WebGL stage that shows the
// Meshy models (cabinet in the hero, Peggoy at the end) through a halftone shader.
import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { MeshoptDecoder } from 'three/addons/libs/meshopt_decoder.module.js';
import { createBoard } from './board.js';
import { sfx, unlock, isMuted, setMuted } from './sound.js';
import { initConnect } from './connect-ui.js';

// Set at launch by `./deploy.sh ca 0x…` (the line format matters).
const CONFIG = {
  ca: '',
  launch: Date.UTC(2026, 9, 3, 15, 0, 0), // Sat 03 Oct 2026 · 15:00 UTC
  pons: 'https://www.ponsfamily.com/launchpad/',
};

const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
const hasGsap = typeof window.gsap !== 'undefined' && typeof window.ScrollTrigger !== 'undefined';
const store = {
  get(k, d) { try { return localStorage.getItem(k) ?? d; } catch { return d; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch { /* ignore */ } },
};

// ---------- countdown ----------
const cd = Object.fromEntries($$('[data-cd]').map((el) => [el.dataset.cd, el]));
const pad = (n) => String(n).padStart(2, '0');
function tick() {
  const left = Math.max(0, CONFIG.launch - Date.now());
  const s = Math.floor(left / 1000);
  cd.d.textContent = pad(Math.floor(s / 86400));
  cd.h.textContent = pad(Math.floor((s % 86400) / 3600));
  cd.m.textContent = pad(Math.floor((s % 3600) / 60));
  cd.s.textContent = pad(s % 60);
  if (!left) { $('#cdLabel').textContent = '$PEGGOY IS LIVE · THE MACHINE IS OPEN'; return false; }
  return true;
}
if (tick()) { const iv = setInterval(() => { if (!tick()) clearInterval(iv); }, 1000); }

// ---------- launch timeline: stages clear as their time passes, the next one lights up ----------
(function stages() {
  const now = Date.now() / 1000;
  const cards = $$('.stage-card[data-at]');
  let next = null;
  cards.forEach((c) => { const done = now >= +c.dataset.at; c.classList.toggle('is-done', done); if (!done && !next) next = c; });
  (next || $('.stage-card:not([data-at])'))?.classList.add('is-next');
})();

// ---------- contract address / buy buttons ----------
(function applyCA() {
  const ca = /^0x[0-9a-fA-F]{40}$/.test(CONFIG.ca) ? CONFIG.ca : '';
  if (!ca) return; // before launch: "SOON", copy disabled, buy buttons scroll to the launch timeline
  const url = CONFIG.pons + ca;
  $$('[data-ca-value]').forEach((el) => (el.textContent = ca));
  $$('[data-ca-copy]').forEach((b) => {
    b.disabled = false;
    b.addEventListener('click', async () => {
      try { await navigator.clipboard.writeText(ca); b.textContent = 'COPIED'; sfx('coin'); } catch { /* clipboard blocked */ }
      setTimeout(() => (b.textContent = 'COPY'), 1400);
    });
  });
  $$('[data-buy]').forEach((a) => {
    a.href = url; a.target = '_blank'; a.rel = 'noopener'; a.removeAttribute('data-scroll');
    a.textContent = a.id === 'buyTop' ? 'Buy $PEGGOY' : a.id === 'buyMain' ? 'Buy $PEGGOY on Pons' : 'Buy on Pons';
  });
})();

// ---------- wallet (topbar) ----------
initConnect();

// ---------- sound toggle ----------
const muteBtn = $('#mute');
const paintMute = () => {
  muteBtn.setAttribute('aria-pressed', String(!isMuted()));
  muteBtn.title = isMuted() ? 'Sound off' : 'Sound on';
  muteBtn.innerHTML = isMuted()
    ? '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M11 5 6 9H3v6h3l5 4zM22 9l-6 6M16 9l6 6"/></svg>'
    : '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M11 5 6 9H3v6h3l5 4zM15.5 8.5a5 5 0 0 1 0 7M18.5 5.5a9 9 0 0 1 0 13"/></svg>';
};
muteBtn.addEventListener('click', () => { setMuted(!isMuted()); paintMute(); unlock(); sfx('coin'); });
paintMute();
addEventListener('pointerdown', unlock, { once: true });

// ---------- practice board + HUD ----------
let score = 0, balls = 0;
let hi = Number(store.get('peggoy-hi', '0')) || 0;
$('#hiscore').textContent = hi;
const board = createBoard($('#board'), {
  onPeg: () => sfx('peg'),
  onDrop: () => { balls++; $('#credits').textContent = pad(Math.min(balls, 99)); sfx('drop'); },
  onScore: (pts) => {
    score += pts;
    $('#score').textContent = score;
    sfx('score', pts >= 100);
    if (score > hi) { hi = score; $('#hiscore').textContent = hi; store.set('peggoy-hi', String(hi)); }
  },
});
$('#drop1').addEventListener('click', () => board.drop());
$('#drop10').addEventListener('click', () => board.dropMany(10));
let boardInView = false;
new IntersectionObserver(([e]) => { boardInView = e.isIntersecting; }, { threshold: 0.3 }).observe($('#board'));
addEventListener('keydown', (e) => {
  if (e.code !== 'Space' || !boardInView || e.target.closest('input, textarea, button, a')) return;
  e.preventDefault(); board.drop();
});

// ---------- topbar: solid after scroll, light/dark follows the section under it ----------
const topbar = $('.topbar');
const themed = $$('[data-theme]');
function paintTopbar() {
  topbar.classList.toggle('is-solid', scrollY > 40);
  const y = 40;
  const sec = themed.find((s) => { const r = s.getBoundingClientRect(); return r.top <= y && r.bottom > y; });
  topbar.classList.toggle('is-light', sec?.dataset.theme === 'light');
}
addEventListener('scroll', paintTopbar, { passive: true });
paintTopbar();

// ---------- manifesto: split into words (keeps <em>) ----------
$$('[data-words]').forEach((p) => {
  const walk = (node) => {
    [...node.childNodes].forEach((n) => {
      if (n.nodeType === 3) {
        const frag = document.createDocumentFragment();
        n.textContent.split(/(\s+)/).forEach((part) => {
          if (!part) return;
          if (/^\s+$/.test(part)) frag.append(part);
          else { const s = document.createElement('span'); s.className = 'w'; s.textContent = part; frag.append(s); }
        });
        n.replaceWith(frag);
      } else if (n.nodeType === 1) walk(n);
    });
  };
  walk(p);
});

// ---------- smooth scroll + scroll animations ----------
let lenis = null;
if (!reduced && window.Lenis) {
  lenis = new window.Lenis({ lerp: 0.1 });
  window.__lenis = lenis; // handy for debugging in the console
  if (hasGsap) {
    lenis.on('scroll', window.ScrollTrigger.update);
    gsap.ticker.add((time) => lenis.raf(time * 1000));
    gsap.ticker.lagSmoothing(0);
  } else {
    const raf = (t) => { lenis.raf(t); requestAnimationFrame(raf); };
    requestAnimationFrame(raf);
  }
}
$$('[data-scroll]').forEach((a) => a.addEventListener('click', (e) => {
  const href = a.getAttribute('href');
  if (!href?.startsWith('#') || !a.hasAttribute('data-scroll')) return;
  const target = href === '#top' ? 0 : $(href);
  if (target === null) return;
  e.preventDefault();
  lenis ? lenis.scrollTo(target, { duration: 1.4 }) : (target === 0 ? scrollTo({ top: 0 }) : target.scrollIntoView());
}));

if (hasGsap && !reduced) {
  gsap.registerPlugin(ScrollTrigger);
  const scrub = (trigger, start, end) => ({ trigger, start, end, scrub: true });
  gsap.to('.hero__inner', { yPercent: -14, opacity: 0, ease: 'none', scrollTrigger: scrub('.hero', 'top top', 'bottom top') });
  gsap.to('.hero__bg', { yPercent: 12, ease: 'none', scrollTrigger: scrub('.hero', 'top top', 'bottom top') });
  $$('[data-words]').forEach((p) => gsap.to(p.querySelectorAll('.w'), { opacity: 1, stagger: 0.06, ease: 'none', scrollTrigger: scrub(p, 'top 80%', 'bottom 45%') }));
  const rise = (sel, trigger) => gsap.from(sel, { y: 60, opacity: 0, duration: 0.9, stagger: 0.12, ease: 'power3.out', scrollTrigger: { trigger, start: 'top 78%' } });
  rise('.step', '.steps');
  rise('.card', '.fair__grid');
  rise('.stage-card', '.stages');
  gsap.from('.split__bar span', { scaleX: 0, transformOrigin: 'left', duration: 1.1, stagger: 0.15, ease: 'power3.out', scrollTrigger: { trigger: '.split', start: 'top 80%' } });
  gsap.from('.slots span', { scaleY: 0, transformOrigin: 'bottom', duration: 0.7, stagger: 0.06, ease: 'back.out(2)', scrollTrigger: { trigger: '.slots', start: 'top 85%' } });
  gsap.from('.cab', { y: 90, rotate: -2, opacity: 0, duration: 1.1, ease: 'power3.out', scrollTrigger: { trigger: '.cab', start: 'top 85%' } });
  gsap.from('.closing__title', { scale: 0.7, opacity: 0, ease: 'none', scrollTrigger: scrub('.closing', 'top 80%', 'center 70%') });
} else {
  $$('.w').forEach((w) => (w.style.opacity = 1));
}

// ---------- 3D stage ----------
const stage = initStage();

function initStage() {
  const canvas = $('#stage');
  let renderer;
  try {
    renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true, powerPreference: 'high-performance' });
  } catch { canvas.remove(); return { ready: Promise.resolve() }; }
  renderer.setPixelRatio(Math.min(devicePixelRatio || 1, 2));
  renderer.setClearColor(0x000000, 0);
  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(32, 1, 0.1, 100);
  camera.position.set(0, 0, 10);

  // Halftone engraving: lit luminance → screen-space dot screen, cream ink on transparent; saturated
  // (orange) parts of the texture keep the accent colour.
  const halftone = (map) => new THREE.ShaderMaterial({
    uniforms: {
      map: { value: map }, hasMap: { value: map ? 1 : 0 },
      paper: { value: new THREE.Color('#f1ead8') }, ink: { value: new THREE.Color('#0d0b14') },
      hot: { value: new THREE.Color('#ff5b14') }, density: { value: 4.2 * renderer.getPixelRatio() },
      fade: { value: 0 },
    },
    transparent: true,
    vertexShader: `
      varying vec2 vUv; varying vec3 vN; varying vec3 vV;
      void main() {
        vUv = uv;
        vec4 mv = modelViewMatrix * vec4(position, 1.0);
        vN = normalize(normalMatrix * normal); vV = normalize(-mv.xyz);
        gl_Position = projectionMatrix * mv;
      }`,
    fragmentShader: `
      uniform sampler2D map; uniform float hasMap; uniform vec3 paper; uniform vec3 ink; uniform vec3 hot;
      uniform float density; uniform float fade;
      varying vec2 vUv; varying vec3 vN; varying vec3 vV;
      void main() {
        vec3 n = normalize(vN);
        vec3 tex = hasMap > 0.5 ? texture2D(map, vUv).rgb : vec3(0.85);
        float light = clamp(dot(n, normalize(vec3(-0.45, 0.65, 0.6))), 0.0, 1.0) * 0.75 + 0.25;
        float rim = pow(1.0 - clamp(dot(n, vV), 0.0, 1.0), 2.5);
        float lum = clamp(dot(tex, vec3(0.299, 0.587, 0.114)) * light + rim * 0.35, 0.0, 1.0);
        float sat = max(tex.r, max(tex.g, tex.b)) - min(tex.r, min(tex.g, tex.b));
        float accent = smoothstep(0.28, 0.5, sat) * step(tex.g, tex.r);
        // 45° dot screen
        vec2 p = gl_FragCoord.xy / density;
        p = mat2(0.7071, -0.7071, 0.7071, 0.7071) * p;
        float d = length(fract(p) - 0.5);
        float r = sqrt(1.0 - lum) * 0.62;
        float dotInk = 1.0 - smoothstep(r - 0.06, r + 0.06, d);
        vec3 base = mix(paper, ink, dotInk);
        vec3 accentCol = mix(hot, mix(hot, ink, 0.5), dotInk * 0.55);
        vec3 col = mix(base, accentCol, accent);
        col += hot * rim * 0.35;
        gl_FragColor = vec4(col, fade);
      }`,
  });

  const models = {};
  const loader = new GLTFLoader();
  loader.setMeshoptDecoder(MeshoptDecoder);
  const load = (name, size) => new Promise((resolve) => {
    loader.load(`assets/models/${name}.glb`, (g) => {
      const root = g.scene;
      const mats = [];
      root.traverse((o) => {
        if (!o.isMesh) return;
        const m = halftone(o.material?.map || null);
        o.material = m; mats.push(m);
      });
      const box = new THREE.Box3().setFromObject(root);
      const s = new THREE.Vector3(); box.getSize(s);
      const c = new THREE.Vector3(); box.getCenter(c);
      root.position.sub(c);
      const pivot = new THREE.Group();
      pivot.add(root);
      pivot.scale.setScalar(size / Math.max(s.x, s.y, s.z));
      pivot.visible = false;
      scene.add(pivot);
      models[name] = { obj: pivot, mats, show: 0, base: pivot.scale.x };
      resolve();
    }, undefined, () => resolve()); // a missing model never blocks the page
  });
  const ready = Promise.all([load('cabinet', 3.9), load('peggoy', 1.6)]);

  // which model, where: driven by the sections that carry data-stage
  const zones = $$('[data-stage]');
  const titleEl = $('.closing__title');
  let w = 0, h = 0, running = false, active = null, scrollK = 0;
  function resize() {
    w = innerWidth; h = innerHeight;
    renderer.setSize(w, h, false);
    camera.aspect = w / h; camera.updateProjectionMatrix();
    for (const m of Object.values(models)) m.mats.forEach((x) => (x.uniforms.density.value = 4.2 * renderer.getPixelRatio()));
  }
  addEventListener('resize', resize);
  resize();

  function pickZone() {
    let best = null, bestVis = 0;
    for (const z of zones) {
      const r = z.getBoundingClientRect();
      const vis = Math.max(0, Math.min(r.bottom, h) - Math.max(r.top, 0)) / h;
      if (vis > bestVis) { bestVis = vis; best = z; }
    }
    if (!best || bestVis < 0.15) return { name: null };
    const r = best.getBoundingClientRect();
    return { name: best.dataset.stage, k: (h - r.top) / (h + r.height), top: r.top }; // k: 0 → entering, 1 → leaving
  }

  const clock = new THREE.Clock();
  function frame() {
    const t = clock.getElapsedTime();
    const z = pickZone();
    active = z.name; scrollK = z.k ?? 0;
    const desktop = w >= 900;
    let anyVisible = false;
    for (const [name, m] of Object.entries(models)) {
      const want = name === active && desktop ? 1 : 0; // phones get the flat mascot instead
      m.show += (want - m.show) * 0.08;
      m.obj.visible = m.show > 0.01;
      m.mats.forEach((x) => (x.uniforms.fade.value = m.show));
      if (!m.obj.visible) continue;
      anyVisible = true;
      if (name === 'cabinet') {
        // scroll with the hero (no fixed overlay over the next section): hero top in px → world units
        const visH = 2 * camera.position.z * Math.tan(THREE.MathUtils.degToRad(camera.fov / 2));
        const heroTop = zones[0].getBoundingClientRect().top;
        const ks = Math.min(1, Math.max(0.55, camera.aspect / 1.6)); // smaller on narrow/portrait viewports
        m.obj.scale.setScalar(m.base * ks);
        const x = Math.min(2.5, visH * camera.aspect * 0.3); // and kept on screen
        m.obj.position.set(desktop ? x : 0, -0.15 - (heroTop / h) * visH, 0);
        m.obj.rotation.set(0.05, -0.55 + scrollK * 2.2 + Math.sin(t * 0.5) * 0.06, 0);
      } else {
        // sit just above the closing title, wherever the layout puts it
        const visH = 2 * camera.position.z * Math.tan(THREE.MathUtils.degToRad(camera.fov / 2));
        const top = titleEl.getBoundingClientRect().top;
        const k = Math.min(1, Math.max(0.55, camera.aspect / 1.1));
        const px = (1.6 * k / visH) * h;                       // Peggoy's height on screen
        const y = (0.5 - (top - px * 0.5 - 52) / h) * visH;     // centre it just above the eyebrow
        m.obj.scale.setScalar(m.base * k);
        m.obj.position.set(0, y + Math.sin(t * 2.2) * 0.12, 0);
        m.obj.rotation.set(0.1, -0.4 + Math.sin(t * 0.8) * 0.5 + scrollK * 1.5, Math.sin(t * 2.2) * 0.06);
      }
    }
    renderer.render(scene, camera);
    if (anyVisible || active) requestAnimationFrame(frame);
    else running = false;
  }
  const wake = () => { if (running) return; running = true; clock.getDelta(); requestAnimationFrame(frame); };
  addEventListener('scroll', wake, { passive: true });
  document.addEventListener('visibilitychange', wake);
  ready.then(wake);
  return { ready };
}

// ---------- boot screen: real work, then PRESS START ----------
(function boot() {
  const el = $('#boot'); if (!el) return;
  const fill = $('#bootFill'), txt = $('#bootTxt');
  let shown = 0.08;
  const set = (v) => { shown = Math.max(shown, v); fill.style.width = Math.round(shown * 100) + '%'; };
  const img = new Promise((r) => { const i = new Image(); i.onload = i.onerror = r; i.src = 'assets/img/hero.webp'; });
  const steps = [document.fonts ? document.fonts.ready : Promise.resolve(), img, stage.ready];
  let done = 0;
  steps.forEach((s) => s.then(() => set(0.1 + (++done / steps.length) * 0.85)));
  const finish = () => {
    if (el.classList.contains('is-gone')) return;
    el.classList.add('is-gone'); document.body.classList.remove('is-locked');
    hasGsap && ScrollTrigger.refresh();
  };
  Promise.race([Promise.all(steps), new Promise((r) => setTimeout(r, 6000))]).then(() => {
    set(1);
    txt.textContent = 'PRESS START';
    txt.classList.add('is-start');
    sfx('start');
    el.addEventListener('click', finish, { once: true });
    setTimeout(finish, 900);
  });
})();

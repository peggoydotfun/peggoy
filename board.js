// Practice pegboard: real 2D ball physics on a canvas. Browser only: no wallet, no prize, nothing sent anywhere.
// The loop runs only while the board is on screen and something is moving.

const W = 400, H = 500;              // logical size, scaled to the canvas
const BALL_R = 7, PEG_R = 4;
const GRAVITY = 980, BOUNCE = 0.48, STEP = 1 / 240;
const SLOT_TOP = 432;
const POINTS = [100, 25, 10, 5, 2, 5, 10, 25, 100];
const SLOT_W = W / POINTS.length;

const INK = '#0d0b14', PAPER = '#f1ead8', HOT = '#ff5b14';

function buildPegs() {
  const pegs = [];
  const rows = 11, gap = 32, top = 96;
  for (let r = 0; r < rows; r++) {
    const off = r % 2 ? gap / 2 : 0;
    for (let x = 24 + off; x <= W - 24; x += gap) pegs.push({ x, y: top + r * 30, hit: -9 });
  }
  return pegs;
}

export function createBoard(canvas, { onPeg, onScore, onDrop } = {}) {
  const ctx = canvas.getContext('2d');
  const pegs = buildPegs();
  const balls = [];
  const flashes = POINTS.map(() => -9);
  let scale = 1, running = false, visible = false, last = 0, acc = 0, t = 0;

  function resize() {
    const r = canvas.getBoundingClientRect();
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    canvas.width = Math.round(r.width * dpr);
    canvas.height = Math.round(r.width * (H / W) * dpr);
    scale = canvas.width / W;
    draw();
  }

  function drop(x = W / 2 + (Math.random() - 0.5) * 60) {
    x = Math.max(BALL_R + 30, Math.min(W - BALL_R - 30, x));
    balls.push({ x, y: 36, vx: (Math.random() - 0.5) * 20, vy: 0, trail: [] });
    onDrop?.();
    start();
  }

  function physics(dt) {
    for (let i = balls.length - 1; i >= 0; i--) {
      const b = balls[i];
      b.vy += GRAVITY * dt;
      b.x += b.vx * dt; b.y += b.vy * dt;

      for (const p of pegs) {
        const dx = b.x - p.x, dy = b.y - p.y, min = BALL_R + PEG_R;
        const d2 = dx * dx + dy * dy;
        if (d2 >= min * min) continue;
        const d = Math.sqrt(d2) || 0.001, nx = dx / d, ny = dy / d;
        b.x = p.x + nx * min; b.y = p.y + ny * min;
        const vn = b.vx * nx + b.vy * ny;
        if (vn < 0) {
          b.vx -= (1 + BOUNCE) * vn * nx; b.vy -= (1 + BOUNCE) * vn * ny;
          b.vx += (Math.random() - 0.5) * 34;   // a peg is never perfectly round
          if (p.hit < t - 0.05) onPeg?.();
          p.hit = t;
        }
      }
      // side walls
      if (b.x < BALL_R) { b.x = BALL_R; b.vx = Math.abs(b.vx) * BOUNCE; }
      if (b.x > W - BALL_R) { b.x = W - BALL_R; b.vx = -Math.abs(b.vx) * BOUNCE; }
      // slot dividers
      if (b.y > SLOT_TOP - BALL_R) {
        for (let k = 1; k < POINTS.length; k++) {
          const wx = k * SLOT_W;
          if (Math.abs(b.x - wx) < BALL_R + 1.5) {
            b.x = b.x < wx ? wx - BALL_R - 1.5 : wx + BALL_R + 1.5;
            b.vx = -b.vx * BOUNCE;
          }
        }
      }
      if (b.y > H - BALL_R - 6) {
        const slot = Math.max(0, Math.min(POINTS.length - 1, Math.floor(b.x / SLOT_W)));
        flashes[slot] = t;
        onScore?.(POINTS[slot], slot);
        balls.splice(i, 1);
      }
    }
  }

  function draw() {
    ctx.setTransform(scale, 0, 0, scale, 0, 0);
    ctx.fillStyle = INK; ctx.fillRect(0, 0, W, H);
    // dot grid
    ctx.fillStyle = 'rgba(241,234,216,.06)';
    for (let y = 6; y < H; y += 10) for (let x = 6; x < W; x += 10) ctx.fillRect(x, y, 1, 1);
    // drop zone hint
    ctx.strokeStyle = 'rgba(255,91,20,.35)'; ctx.setLineDash([4, 6]); ctx.lineWidth = 1;
    ctx.beginPath(); ctx.moveTo(30, 60); ctx.lineTo(W - 30, 60); ctx.stroke(); ctx.setLineDash([]);
    // pegs
    for (const p of pegs) {
      const k = Math.max(0, 1 - (t - p.hit) / 0.35);
      if (k > 0) { ctx.fillStyle = `rgba(255,91,20,${0.35 * k})`; ctx.beginPath(); ctx.arc(p.x, p.y, PEG_R + 7 * k, 0, 7); ctx.fill(); }
      ctx.fillStyle = k > 0 ? HOT : PAPER;
      ctx.beginPath(); ctx.arc(p.x, p.y, PEG_R, 0, 7); ctx.fill();
    }
    // slots
    for (let k = 0; k < POINTS.length; k++) {
      const x = k * SLOT_W, f = Math.max(0, 1 - (t - flashes[k]) / 0.6);
      const top = POINTS[k] >= 100;
      ctx.fillStyle = f > 0 ? `rgba(255,91,20,${0.25 + 0.6 * f})` : top ? 'rgba(255,91,20,.16)' : 'rgba(241,234,216,.05)';
      ctx.fillRect(x + 2, SLOT_TOP, SLOT_W - 4, H - SLOT_TOP);
      ctx.fillStyle = f > 0.3 ? INK : top ? HOT : 'rgba(241,234,216,.75)';
      ctx.font = '9px "Press Start 2P", monospace'; ctx.textAlign = 'center';
      ctx.fillText(String(POINTS[k]), x + SLOT_W / 2, H - 22);
    }
    ctx.fillStyle = PAPER;
    for (let k = 1; k < POINTS.length; k++) ctx.fillRect(k * SLOT_W - 1.5, SLOT_TOP, 3, H - SLOT_TOP);
    // balls
    for (const b of balls) {
      b.trail.push(b.x, b.y); if (b.trail.length > 16) b.trail.splice(0, 2);
      for (let i = 0; i < b.trail.length; i += 2) {
        ctx.fillStyle = `rgba(255,91,20,${(i / b.trail.length) * 0.35})`;
        ctx.beginPath(); ctx.arc(b.trail[i], b.trail[i + 1], BALL_R * (i / b.trail.length), 0, 7); ctx.fill();
      }
      ctx.fillStyle = HOT; ctx.beginPath(); ctx.arc(b.x, b.y, BALL_R, 0, 7); ctx.fill();
      ctx.fillStyle = 'rgba(255,255,255,.55)'; ctx.beginPath(); ctx.arc(b.x - 2.4, b.y - 2.4, 2.2, 0, 7); ctx.fill();
    }
  }

  function frame(now) {
    if (!running) return;
    const dt = Math.min(0.05, (now - last) / 1000 || 0);
    last = now; acc += dt;
    while (acc >= STEP) { physics(STEP); t += STEP; acc -= STEP; }
    draw();
    const busy = balls.length || flashes.some((f) => t - f < 0.6) || pegs.some((p) => t - p.hit < 0.35);
    if (busy && visible) requestAnimationFrame(frame);
    else running = false;
  }
  function start() {
    if (running || !visible) return;
    running = true; last = performance.now(); requestAnimationFrame(frame);
  }

  canvas.addEventListener('pointerdown', (e) => {
    const r = canvas.getBoundingClientRect();
    drop(((e.clientX - r.left) / r.width) * W);
  });
  new IntersectionObserver(([en]) => { visible = en.isIntersecting; if (visible && balls.length) start(); }, { threshold: 0.05 }).observe(canvas);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) start(); });
  window.addEventListener('resize', resize);
  resize();
  document.fonts?.ready.then(draw);

  return { drop, dropMany(n = 10) { for (let i = 0; i < n; i++) setTimeout(() => drop(), i * 140); } };
}

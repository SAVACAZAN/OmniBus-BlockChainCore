import { useEffect, useRef } from "react";

function lerp(a: number, b: number, t: number) {
  return a + (b - a) * t;
}

function clamp01(t: number) {
  return Math.max(0, Math.min(1, t));
}

function easeInOut(t: number) {
  return t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2;
}

function easeOutBack(t: number) {
  const c1 = 1.70158;
  const c3 = c1 + 1;
  return 1 + c3 * Math.pow(t - 1, 3) + c1 * Math.pow(t - 1, 2);
}

function hslToHex(h: number, s: number, l: number) {
  s /= 100;
  l /= 100;
  const k = (n: number) => (n + h / 30) % 12;
  const a = s * Math.min(l, 1 - l);
  const f = (n: number) => {
    const v = l - a * Math.max(-1, Math.min(k(n) - 3, Math.min(9 - k(n), 1)));
    return Math.round(v * 255)
      .toString(16)
      .padStart(2, "0");
  };
  return `#${f(0)}${f(8)}${f(4)}`;
}

function randomPalette(seed: number) {
  const rng = () => {
    seed = (seed * 9301 + 49297) % 233280;
    return seed / 233280;
  };
  const secondaryHue = 60 + Math.floor(rng() * 280);
  const secondary = hslToHex(secondaryHue, 80 + rng() * 20, 45 + rng() * 15);
  const secondaryLight = hslToHex(secondaryHue, 70, 70);
  const secondaryDark = hslToHex(secondaryHue, 90, 35);
  const accent = hslToHex((secondaryHue + 180) % 360, 60 + rng() * 30, 50 + rng() * 20);
  return {
    orangeMain: "#ff7f50",
    orangeDark: "#ff4500",
    orangeSpark: "#ffffff",
    secMain: secondary,
    secLight: secondaryLight,
    secDark: secondaryDark,
    accent,
    mix: hslToHex(Math.floor(lerp(35, secondaryHue, 0.5)), 80, 55),
  };
}

const EXCHANGE_LABELS = [
  "LCX", "Kraken", "Coinbase", "Binance", "Bybit",
  "OKX", "Gate.io", "KuCoin", "MEXC", "Bitget",
  "Electric Fonts", "Lugn",
];

export function ZeroDayPage() {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    const W = 960;
    const H = 540;
    const dpr = window.devicePixelRatio || 1;
    canvas.width = W * dpr;
    canvas.height = H * dpr;
    ctx.scale(dpr, dpr);

    const cx = W / 2;
    const cy = H / 2;

    let startTime = performance.now();
    let paletteSeed = Math.random() * 100000;
    let palette = randomPalette(paletteSeed);
    let cycle = 0;
    let raf = 0;

    function randomSpawn() {
      const margin = 60;
      return {
        x: margin + Math.random() * (W - margin * 2),
        y: margin + Math.random() * (H - margin * 2),
      };
    }
    let spawnPoints = [randomSpawn(), randomSpawn()];
    // ensure they're not too close to center or each other
    while (Math.hypot(spawnPoints[0].x - cx, spawnPoints[0].y - cy) < 120) spawnPoints[0] = randomSpawn();
    while (Math.hypot(spawnPoints[1].x - cx, spawnPoints[1].y - cy) < 120 ||
           Math.hypot(spawnPoints[1].x - spawnPoints[0].x, spawnPoints[1].y - spawnPoints[0].y) < 100) {
      spawnPoints[1] = randomSpawn();
    }

    const CYCLE_DURATION = 56;

    const STAGES = [
      { t: 0, label: "Seed" },
      { t: 6, label: "Orange Plasma Awakens" },
      { t: 16, label: "Spark" },
      { t: 26, label: "Plasma Split" },
      { t: 36, label: "Convergence" },
      { t: 46, label: "OmniBus 0day" },
      { t: CYCLE_DURATION, label: "" },
    ];

    function getStageProgress(elapsed: number) {
      for (let i = 0; i < STAGES.length - 1; i++) {
        if (elapsed >= STAGES[i].t && elapsed < STAGES[i + 1].t) {
          const dur = STAGES[i + 1].t - STAGES[i].t;
          return { stage: i, local: clamp01((elapsed - STAGES[i].t) / dur), label: STAGES[i].label };
        }
      }
      return { stage: 5, local: 1, label: STAGES[5].label };
    }

    function drawRays(
      cx: number,
      cy: number,
      baseLen: number,
      numRays: number,
      time: number,
      colorMain: string,
      colorSpark: string,
      shadowColor: string,
      alpha: number,
      scale: number
    ) {
      ctx.globalAlpha = alpha;
      for (let i = 0; i < numRays; i++) {
        const angle = (i / numRays) * Math.PI * 2;
        const len = baseLen * scale + Math.sin(time + i) * 4 * scale;
        ctx.beginPath();
        ctx.lineWidth = (0.8 + Math.random() * 1.2) * scale;
        ctx.strokeStyle = Math.random() > 0.15 ? colorMain : colorSpark;
        ctx.shadowBlur = 10 * scale;
        ctx.shadowColor = shadowColor;
        let lx = cx;
        let ly = cy;
        for (let j = 0; j < 5; j++) {
          const seg = len / 5;
          const nx = cx + Math.cos(angle) * (j + 1) * seg + (Math.random() - 0.5) * 8 * scale;
          const ny = cy + Math.sin(angle) * (j + 1) * seg + (Math.random() - 0.5) * 8 * scale;
          ctx.moveTo(lx, ly);
          ctx.lineTo(nx, ny);
          lx = nx;
          ly = ny;
        }
        ctx.stroke();
        ctx.beginPath();
        ctx.arc(lx, ly, Math.random() * 2 * scale, 0, Math.PI * 2);
        ctx.fillStyle = colorSpark;
        ctx.fill();
      }
      ctx.globalAlpha = 1;
    }

    function drawOrb(cx: number, cy: number, r: number, colors: string[]) {
      const grad = ctx.createRadialGradient(cx, cy, r * 0.1, cx, cy, r);
      colors.forEach((c, i) => grad.addColorStop(i / (colors.length - 1), c));
      ctx.fillStyle = grad;
      ctx.beginPath();
      ctx.arc(cx, cy, r, 0, Math.PI * 2);
      ctx.fill();
    }

    function drawText(label: string, sub?: string) {
      ctx.shadowBlur = 0;
      ctx.fillStyle = "#e5e7eb";
      ctx.font = "bold 22px monospace";
      ctx.textAlign = "center";
      ctx.fillText(label, W / 2, H - 48);
      if (sub) {
        ctx.fillStyle = "#9ca3af";
        ctx.font = "13px monospace";
        ctx.fillText(sub, W / 2, H - 24);
      }
    }

    function drawSketchyLine(x1: number, y1: number, x2: number, y2: number, color: string, width = 1) {
      ctx.strokeStyle = color;
      ctx.lineWidth = width;
      ctx.beginPath();
      const steps = 12;
      for (let i = 0; i <= steps; i++) {
        const t = i / steps;
        const nx = lerp(x1, x2, t) + (Math.random() - 0.5) * 3;
        const ny = lerp(y1, y2, t) + (Math.random() - 0.5) * 3;
        if (i === 0) ctx.moveTo(nx, ny);
        else ctx.lineTo(nx, ny);
      }
      ctx.stroke();
    }

    function drawExchangeSketch(cx: number, cy: number, time: number, reveal: number) {
      // reveal: 0..1 — cât de mult apar etichetele
      const count = EXCHANGE_LABELS.length;
      const radius = 160 + Math.sin(time * 0.5) * 10;
      const rotation = time * 0.3;

      ctx.textAlign = "center";
      ctx.textBaseline = "middle";

      for (let i = 0; i < count; i++) {
        const t = i / count;
        const angle = t * Math.PI * 2 + rotation;
        const x = cx + Math.cos(angle) * radius;
        const y = cy + Math.sin(angle) * radius;

        const itemReveal = clamp01((reveal - t * 0.3) / 0.15);
        if (itemReveal <= 0) continue;

        const pop = easeOutBack(itemReveal);
        const sx = lerp(cx, x, pop);
        const sy = lerp(cy, y, pop);
        const alpha = itemReveal;

        // Linie sketchy de la centru spre etichetă
        if (itemReveal > 0.3) {
          ctx.globalAlpha = alpha * 0.35;
          drawSketchyLine(cx + Math.cos(angle) * 30, cy + Math.sin(angle) * 30, sx, sy, palette.orangeMain, 0.8);
        }

        // Cerc mic sketchy în jurul textului
        ctx.globalAlpha = alpha * 0.2;
        ctx.strokeStyle = palette.secMain;
        ctx.lineWidth = 1;
        ctx.beginPath();
        const jitter = 2;
        for (let a = 0; a < Math.PI * 2; a += 0.4) {
          const rr = 18 + Math.random() * jitter;
          const px = sx + Math.cos(a) * rr;
          const py = sy + Math.sin(a) * rr;
          if (a === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
        }
        ctx.closePath();
        ctx.stroke();

        // Text
        ctx.globalAlpha = alpha;
        ctx.fillStyle = i % 2 === 0 ? "#d1d5db" : palette.secLight;
        ctx.font = `${i % 3 === 0 ? "italic " : ""}13px "Courier New", monospace`;
        ctx.fillText(EXCHANGE_LABELS[i], sx, sy);

        // Sub-linie sub text
        ctx.globalAlpha = alpha * 0.5;
        ctx.strokeStyle = palette.orangeDark;
        ctx.lineWidth = 0.5;
        const tw = ctx.measureText(EXCHANGE_LABELS[i]).width;
        ctx.beginPath();
        ctx.moveTo(sx - tw / 2, sy + 10);
        ctx.lineTo(sx + tw / 2, sy + 10);
        ctx.stroke();
      }
      ctx.globalAlpha = 1;
    }

    // ── Lightning bolts ──────────────────────────────────────────────────────
    type Lightning = {
      x: number; y: number;        // start (top edge)
      segs: { dx: number; dy: number }[];
      life: number; maxLife: number;
      color: string; width: number;
    };
    const lightnings: Lightning[] = [];
    let nextLightning = 1.5 + Math.random() * 2;

    function spawnLightning() {
      const x = 80 + Math.random() * (W - 160);
      const totalH = 120 + Math.random() * 220;
      const segs: { dx: number; dy: number }[] = [];
      const n = 8 + Math.floor(Math.random() * 6);
      for (let i = 0; i < n; i++) {
        segs.push({ dx: (Math.random() - 0.5) * 70, dy: totalH / n });
      }
      const hue = Math.random() > 0.5 ? 55 : 200 + Math.random() * 60; // yellow or blue-white
      const color = hslToHex(hue, 100, 85);
      lightnings.push({ x, y: 0, segs, life: 0, maxLife: 0.35 + Math.random() * 0.25, color, width: 1.5 + Math.random() * 2 });
    }

    function drawLightnings(dt: number) {
      for (let i = lightnings.length - 1; i >= 0; i--) {
        const l = lightnings[i];
        l.life += dt;
        if (l.life >= l.maxLife) { lightnings.splice(i, 1); continue; }
        const p = l.life / l.maxLife;
        const alpha = p < 0.2 ? p / 0.2 : 1 - (p - 0.2) / 0.8;
        ctx.globalAlpha = alpha * 0.9;
        ctx.strokeStyle = l.color;
        ctx.lineWidth = l.width * (1 - p * 0.5);
        ctx.shadowColor = l.color;
        ctx.shadowBlur = 18;
        ctx.beginPath();
        let lx = l.x, ly = l.y;
        ctx.moveTo(lx, ly);
        for (const seg of l.segs) {
          lx += seg.dx + (Math.random() - 0.5) * 12;
          ly += seg.dy;
          ctx.lineTo(lx, ly);
        }
        ctx.stroke();
        // glow core
        ctx.lineWidth = l.width * 0.4;
        ctx.strokeStyle = "#ffffff";
        ctx.globalAlpha = alpha * 0.6;
        ctx.beginPath();
        lx = l.x; ly = l.y;
        ctx.moveTo(lx, ly);
        for (const seg of l.segs) {
          lx += seg.dx + (Math.random() - 0.5) * 6;
          ly += seg.dy;
          ctx.lineTo(lx, ly);
        }
        ctx.stroke();
        ctx.globalAlpha = 1;
        ctx.shadowBlur = 0;
      }
    }

    // ── Floating symbols (star ★ + heart ♥) ─────────────────────────────────
    type FloatSymbol = {
      x: number; y: number; vy: number; vx: number;
      symbol: string; size: number; color: string;
      life: number; maxLife: number; rotation: number; rotSpeed: number;
    };
    const floatSymbols: FloatSymbol[] = [];
    let nextSymbol = 2 + Math.random() * 3;

    function spawnSymbol() {
      const isHeart = Math.random() < 0.4;
      const x = 60 + Math.random() * (W - 120);
      const y = H - 40;
      const hue = isHeart ? 350 + Math.random() * 20 : 45 + Math.random() * 30;
      floatSymbols.push({
        x, y,
        vx: (Math.random() - 0.5) * 40,
        vy: -(60 + Math.random() * 80),
        symbol: isHeart ? "♥" : "★",
        size: 16 + Math.random() * 20,
        color: hslToHex(hue, 100, 70),
        life: 0,
        maxLife: 2.5 + Math.random() * 1.5,
        rotation: (Math.random() - 0.5) * 0.4,
        rotSpeed: (Math.random() - 0.5) * 1.5,
      });
    }

    function drawFloatSymbols(dt: number) {
      for (let i = floatSymbols.length - 1; i >= 0; i--) {
        const s = floatSymbols[i];
        s.life += dt;
        s.x += s.vx * dt;
        s.y += s.vy * dt;
        s.vy += 15 * dt; // light gravity
        s.rotation += s.rotSpeed * dt;
        if (s.life >= s.maxLife) { floatSymbols.splice(i, 1); continue; }
        const p = s.life / s.maxLife;
        const alpha = p < 0.15 ? p / 0.15 : p > 0.7 ? 1 - (p - 0.7) / 0.3 : 1;
        const scale = p < 0.15 ? easeOutBack(p / 0.15) : 1;
        ctx.save();
        ctx.translate(s.x, s.y);
        ctx.rotate(s.rotation);
        ctx.scale(scale, scale);
        ctx.globalAlpha = alpha * 0.95;
        ctx.fillStyle = s.color;
        ctx.shadowColor = s.color;
        ctx.shadowBlur = 20;
        ctx.font = `${s.size}px serif`;
        ctx.textAlign = "center";
        ctx.textBaseline = "middle";
        ctx.fillText(s.symbol, 0, 0);
        // second pass slightly larger, lower alpha — glow ring
        ctx.globalAlpha = alpha * 0.25;
        ctx.font = `${s.size * 1.6}px serif`;
        ctx.fillText(s.symbol, 0, 0);
        ctx.restore();
        ctx.globalAlpha = 1;
        ctx.shadowBlur = 0;
      }
    }

    // ── Meteor shower ─────────────────────────────────────────────────────────
    type Meteor = {
      x: number; y: number;
      vx: number; vy: number;
      len: number; size: number;
      life: number; maxLife: number;
      color: string;
    };
    const meteors: Meteor[] = [];
    let nextMeteor = 0.3 + Math.random() * 0.5;

    function spawnMeteor() {
      const angle = Math.PI * 0.18 + Math.random() * 0.2; // steep diagonal
      const speed = 600 + Math.random() * 500;
      const x = Math.random() * W;
      const y = -20;
      const hue = Math.random() > 0.6 ? 35 : 200 + Math.random() * 40;
      meteors.push({
        x, y,
        vx: Math.cos(angle) * speed,
        vy: Math.sin(angle) * speed,
        len: 60 + Math.random() * 100,
        size: 1 + Math.random() * 2,
        life: 0,
        maxLife: 0.5 + Math.random() * 0.4,
        color: hslToHex(hue, 90, 75),
      });
    }

    function drawMeteors(dt: number) {
      for (let i = meteors.length - 1; i >= 0; i--) {
        const m = meteors[i];
        m.life += dt;
        m.x += m.vx * dt;
        m.y += m.vy * dt;
        if (m.life >= m.maxLife || m.y > H + 40) { meteors.splice(i, 1); continue; }
        const p = m.life / m.maxLife;
        const alpha = p < 0.15 ? p / 0.15 : 1 - (p - 0.15) / 0.85;
        const tailX = m.x - Math.cos(Math.PI * 0.18) * m.len * (1 - p * 0.4);
        const tailY = m.y - Math.sin(Math.PI * 0.18) * m.len * (1 - p * 0.4);
        const grad = ctx.createLinearGradient(tailX, tailY, m.x, m.y);
        grad.addColorStop(0, "transparent");
        grad.addColorStop(1, m.color);
        ctx.globalAlpha = alpha * 0.85;
        ctx.strokeStyle = grad;
        ctx.lineWidth = m.size;
        ctx.shadowColor = m.color;
        ctx.shadowBlur = 8;
        ctx.beginPath();
        ctx.moveTo(tailX, tailY);
        ctx.lineTo(m.x, m.y);
        ctx.stroke();
        // head spark
        ctx.globalAlpha = alpha;
        ctx.fillStyle = "#ffffff";
        ctx.shadowBlur = 12;
        ctx.beginPath();
        ctx.arc(m.x, m.y, m.size * 0.8, 0, Math.PI * 2);
        ctx.fill();
        ctx.globalAlpha = 1;
        ctx.shadowBlur = 0;
      }
    }

    // ── Fireworks ─────────────────────────────────────────────────────────────
    type FWParticle = { x: number; y: number; vx: number; vy: number; life: number; maxLife: number; color: string; size: number; };
    type Firework = { x: number; y: number; vy: number; life: number; maxLife: number; color: string; burst: boolean; particles: FWParticle[]; };
    const fireworks: Firework[] = [];
    let nextFirework = 1 + Math.random() * 2;

    function spawnFirework() {
      const x = 80 + Math.random() * (W - 160);
      const targetY = 60 + Math.random() * (H * 0.45);
      const hue = Math.floor(Math.random() * 360);
      fireworks.push({ x, y: H - 20, vy: -(targetY + (H - 20)) / 0.6, life: 0, maxLife: 0.6 + Math.random() * 0.2, color: hslToHex(hue, 100, 65), burst: false, particles: [] });
    }

    function burstFirework(fw: Firework) {
      const count = 28 + Math.floor(Math.random() * 20);
      for (let i = 0; i < count; i++) {
        const angle = (i / count) * Math.PI * 2 + Math.random() * 0.3;
        const speed = 60 + Math.random() * 120;
        fw.particles.push({ x: fw.x, y: fw.y, vx: Math.cos(angle) * speed, vy: Math.sin(angle) * speed, life: 0, maxLife: 0.8 + Math.random() * 0.6, color: fw.color, size: 1.5 + Math.random() * 2 });
      }
    }

    function drawFireworks(dt: number) {
      for (let i = fireworks.length - 1; i >= 0; i--) {
        const fw = fireworks[i];
        if (!fw.burst) {
          fw.y += fw.vy * dt;
          fw.life += dt;
          if (fw.life >= fw.maxLife) { fw.burst = true; fw.y = Math.max(fw.y, 40); burstFirework(fw); }
          // rocket trail
          ctx.globalAlpha = 0.85;
          ctx.strokeStyle = fw.color;
          ctx.lineWidth = 2;
          ctx.shadowColor = fw.color; ctx.shadowBlur = 12;
          ctx.beginPath(); ctx.moveTo(fw.x, fw.y + 10); ctx.lineTo(fw.x + (Math.random()-0.5)*4, fw.y); ctx.stroke();
          ctx.globalAlpha = 1; ctx.shadowBlur = 0;
        } else {
          let alive = false;
          for (let j = fw.particles.length - 1; j >= 0; j--) {
            const p = fw.particles[j];
            p.life += dt; p.x += p.vx * dt; p.y += p.vy * dt; p.vy += 120 * dt;
            if (p.life >= p.maxLife) { fw.particles.splice(j, 1); continue; }
            alive = true;
            const a = 1 - p.life / p.maxLife;
            ctx.globalAlpha = a * 0.9;
            ctx.fillStyle = p.color; ctx.shadowColor = p.color; ctx.shadowBlur = 8;
            ctx.beginPath(); ctx.arc(p.x, p.y, p.size * a, 0, Math.PI * 2); ctx.fill();
          }
          ctx.globalAlpha = 1; ctx.shadowBlur = 0;
          if (!alive) fireworks.splice(i, 1);
        }
      }
    }

    // ── Fire emitters ──────────────────────────────────────────────────────────
    type Flame = { x: number; y: number; vx: number; vy: number; life: number; maxLife: number; size: number; hue: number; };
    const flames: Flame[] = [];
    // 3 fire sources along the bottom
    const fireSources = [W * 0.15, W * 0.5, W * 0.85];

    function spawnFlames() {
      for (const sx of fireSources) {
        for (let k = 0; k < 3; k++) {
          flames.push({ x: sx + (Math.random()-0.5)*24, y: H - 10, vx: (Math.random()-0.5)*18, vy: -(80 + Math.random()*120), life: 0, maxLife: 0.6 + Math.random()*0.5, size: 8 + Math.random()*14, hue: 15 + Math.random()*30 });
        }
      }
    }
    let nextFlame = 0;

    function drawFlames(dt: number) {
      for (let i = flames.length - 1; i >= 0; i--) {
        const f = flames[i];
        f.life += dt; f.x += f.vx * dt; f.y += f.vy * dt; f.vy *= 0.98;
        if (f.life >= f.maxLife) { flames.splice(i, 1); continue; }
        const p = f.life / f.maxLife;
        const alpha = p < 0.2 ? p/0.2 : 1 - (p-0.2)/0.8;
        const hue = f.hue + p * 25; // orange → yellow → white
        const size = f.size * (1 - p * 0.4);
        ctx.globalAlpha = alpha * 0.75;
        ctx.fillStyle = hslToHex(hue, 100, 55 + p*30);
        ctx.shadowColor = hslToHex(f.hue, 100, 50); ctx.shadowBlur = 20;
        ctx.beginPath(); ctx.arc(f.x, f.y, size, 0, Math.PI*2); ctx.fill();
      }
      ctx.globalAlpha = 1; ctx.shadowBlur = 0;
    }

    // ── Puppy patrol 🐶 ───────────────────────────────────────────────────────
    const PUPPY_EMOJIS = ["🐶","🐕","🐩","🦮","🐕‍🦺"];
    type Puppy = { x: number; y: number; dir: number; speed: number; emoji: string; bounce: number; life: number; };
    const puppies: Puppy[] = [];
    // spawn initial patrol
    for (let i = 0; i < 4; i++) {
      const dir = Math.random() < 0.5 ? 1 : -1;
      puppies.push({ x: (i / 4) * W + Math.random()*80, y: H - 32, dir, speed: 55 + Math.random()*40, emoji: PUPPY_EMOJIS[i % PUPPY_EMOJIS.length], bounce: Math.random()*Math.PI*2, life: 0 });
    }
    let nextPuppy = 6 + Math.random() * 8;

    function updateAndDrawPuppies(dt: number) {
      // spawn extra puppy occasionally
      nextPuppy -= dt;
      if (nextPuppy <= 0 && puppies.length < 7) {
        const dir = Math.random() < 0.5 ? 1 : -1;
        puppies.push({ x: dir > 0 ? -30 : W + 30, y: H - 32, dir, speed: 60 + Math.random()*50, emoji: PUPPY_EMOJIS[Math.floor(Math.random()*PUPPY_EMOJIS.length)], bounce: 0, life: 0 });
        nextPuppy = 4 + Math.random() * 6;
      }
      for (let i = puppies.length - 1; i >= 0; i--) {
        const p = puppies[i];
        p.life += dt;
        p.x += p.dir * p.speed * dt;
        p.bounce += dt * 6;
        const bobY = Math.abs(Math.sin(p.bounce)) * 5;
        // bounce off walls
        if (p.x > W + 40) p.dir = -1;
        if (p.x < -40) p.dir = 1;
        const drawY = p.y - bobY;
        ctx.save();
        ctx.scale(p.dir < 0 ? -1 : 1, 1);
        const drawX = p.dir < 0 ? -p.x : p.x;
        ctx.font = "22px serif";
        ctx.textAlign = "center";
        ctx.textBaseline = "bottom";
        ctx.globalAlpha = 0.95;
        ctx.fillText(p.emoji, drawX, drawY);
        ctx.restore();
        ctx.globalAlpha = 1;
      }
    }

    let lastTime = performance.now();

    const draw = () => {
      const now = performance.now();
      const dt = Math.min((now - lastTime) / 1000, 0.05);
      lastTime = now;

      // spawn lightning
      nextLightning -= dt;
      if (nextLightning <= 0) {
        spawnLightning();
        if (Math.random() < 0.3) spawnLightning(); // double strike
        nextLightning = 1.2 + Math.random() * 3;
      }
      // spawn meteors — burst of 2-5 every interval
      nextMeteor -= dt;
      if (nextMeteor <= 0) {
        const burst = 2 + Math.floor(Math.random() * 4);
        for (let b = 0; b < burst; b++) spawnMeteor();
        nextMeteor = 0.4 + Math.random() * 1.2;
      }
      // spawn floating symbols (★ ♥)
      nextSymbol -= dt;
      if (nextSymbol <= 0) {
        spawnSymbol();
        if (Math.random() < 0.25) spawnSymbol();
        nextSymbol = 1.8 + Math.random() * 3;
      }
      // spawn fireworks
      nextFirework -= dt;
      if (nextFirework <= 0) {
        spawnFirework();
        if (Math.random() < 0.4) spawnFirework();
        nextFirework = 1.5 + Math.random() * 3;
      }
      // spawn flames continuously
      nextFlame -= dt;
      if (nextFlame <= 0) {
        spawnFlames();
        nextFlame = 0.08;
      }
      let elapsed = (now - startTime) / 1000;

      if (elapsed >= CYCLE_DURATION) {
        cycle += 1;
        startTime = now;
        paletteSeed = Math.random() * 100000;
        palette = randomPalette(paletteSeed);
        spawnPoints = [randomSpawn(), randomSpawn()];
        while (Math.hypot(spawnPoints[0].x - cx, spawnPoints[0].y - cy) < 120) spawnPoints[0] = randomSpawn();
        while (Math.hypot(spawnPoints[1].x - cx, spawnPoints[1].y - cy) < 120 ||
               Math.hypot(spawnPoints[1].x - spawnPoints[0].x, spawnPoints[1].y - spawnPoints[0].y) < 100) {
          spawnPoints[1] = randomSpawn();
        }
        elapsed = 0;
      }

      const { stage, local, label } = getStageProgress(elapsed);
      const e = easeInOut(local);
      const t = elapsed * 0.8;

      ctx.fillStyle = "#0b0b10";
      ctx.fillRect(0, 0, W, H);

      // Grid subtle
      ctx.strokeStyle = "rgba(255,255,255,0.03)";
      ctx.lineWidth = 1;
      for (let x = 0; x < W; x += 40) {
        ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, H); ctx.stroke();
      }
      for (let y = 0; y < H; y += 40) {
        ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(W, y); ctx.stroke();
      }

      // Foc jos, meteoriți, fulgere, simboluri — sub plasma
      drawFlames(dt);
      drawMeteors(dt);
      drawLightnings(dt);
      drawFloatSymbols(dt);
      drawFireworks(dt);

      if (stage === 0) {
        const r = lerp(12, 28, e);
        const pulse = 1 + Math.sin(t * 3) * 0.15;
        drawOrb(cx, cy, r * pulse, ["#fff7cc", "#ffcc00", "#ff9900", "transparent"]);
        drawText(label, `Cycle #${cycle + 1} — A tiny seed of light…`);
      } else if (stage === 1) {
        const orbR = lerp(28, 18, e);
        const rayLen = lerp(0, 70, e);
        const alpha = lerp(0.3, 1, e);
        drawOrb(cx, cy, orbR, ["#ffffff", palette.orangeMain, palette.orangeDark, "transparent"]);
        drawRays(cx, cy, rayLen, 22, t, palette.orangeMain, palette.orangeSpark, palette.orangeDark, alpha, 1.2);
        drawText(label, "The orange plasma ignites…");
      } else if (stage === 2) {
        drawOrb(cx, cy, 18 + Math.sin(t * 2) * 3, ["#ffffff", palette.orangeMain, palette.orangeDark, "transparent"]);
        drawRays(cx, cy, 70, 22, t, palette.orangeMain, palette.orangeSpark, palette.orangeDark, 1, 1.2);

        const sx = spawnPoints[0].x;
        const sy = spawnPoints[0].y;
        const greenR = lerp(8, 22, e);
        const greenPulse = 1 + Math.sin(t * 4) * 0.2;
        drawOrb(sx, sy, greenR * greenPulse, [palette.secLight, palette.secMain, palette.secDark, "transparent"]);
        drawRays(sx, sy, lerp(0, 35, e), 14, t + 1, palette.secMain, palette.secLight, palette.secMain, e, 0.8);
        drawText(label, `A ${palette.secMain} spark emerges…`);
      } else if (stage === 3) {
        drawOrb(cx, cy, 18 + Math.sin(t * 2) * 3, ["#ffffff", palette.orangeMain, palette.orangeDark, "transparent"]);
        drawRays(cx, cy, 70, 22, t, palette.orangeMain, palette.orangeSpark, palette.orangeDark, 1, 1.2);

        const split = e;
        // Bila 1 rămâne la spawnPoints[0], bila 2 apare la spawnPoints[1]
        const g1x = spawnPoints[0].x;
        const g1y = spawnPoints[0].y;
        const g2x = lerp(g1x, spawnPoints[1].x, split);
        const g2y = lerp(g1y, spawnPoints[1].y, split);
        const gR = lerp(22, 16, split);
        const rayL = lerp(35, 45, split);
        const a = lerp(0.6, 0.95, split);

        drawOrb(g1x, g1y, gR + Math.sin(t * 3) * 2, [palette.secLight, palette.secMain, palette.secDark, "transparent"]);
        drawRays(g1x, g1y, rayL, 14, t + 1, palette.secMain, palette.secLight, palette.secMain, a, 0.8);

        drawOrb(g2x, g2y, gR + Math.sin(t * 3 + 1) * 2, [palette.secLight, palette.secMain, palette.secDark, "transparent"]);
        drawRays(g2x, g2y, rayL, 14, t + 2, palette.secMain, palette.secLight, palette.secMain, a, 0.8);

        // Linie sketchy între bile
        ctx.globalAlpha = split * 0.3;
        drawSketchyLine(g1x, g1y, g2x, g2y, palette.secLight, 0.6);
        ctx.globalAlpha = 1;

        drawText(label, "The plasma splits in two…");
      } else if (stage === 4) {
        const move = e;
        // Bilele pleacă de la spawnPoints și converg spre centrul orange
        const g1x = lerp(spawnPoints[0].x, cx - 60, move);
        const g1y = lerp(spawnPoints[0].y, cy, move);
        const g2x = lerp(spawnPoints[1].x, cx + 60, move);
        const g2y = lerp(spawnPoints[1].y, cy, move);
        const gR = lerp(16, 12, move) + Math.sin(t * 3) * 2;
        const mergeAlpha = lerp(0.95, 0.5, move);

        drawOrb(cx, cy, 18 + Math.sin(t * 2) * 3, ["#ffffff", palette.orangeMain, palette.orangeDark, "transparent"]);
        drawRays(cx, cy, 70, 22, t, palette.orangeMain, palette.orangeSpark, palette.orangeDark, 1, 1.2);

        drawOrb(g1x, g1y, gR, [palette.secLight, palette.secMain, palette.secDark, "transparent"]);
        drawRays(g1x, g1y, 45, 14, t + 1, palette.secMain, palette.secLight, palette.secMain, mergeAlpha, 0.8);

        drawOrb(g2x, g2y, gR, [palette.secLight, palette.secMain, palette.secDark, "transparent"]);
        drawRays(g2x, g2y, 45, 14, t + 2, palette.secMain, palette.secLight, palette.secMain, mergeAlpha, 0.8);

        // Linii de tragere spre centru
        ctx.globalAlpha = lerp(0, 0.35, move);
        ctx.strokeStyle = palette.secLight;
        ctx.lineWidth = 0.8;
        drawSketchyLine(g1x, g1y, cx - 30, cy, palette.secLight, 0.7);
        drawSketchyLine(g2x, g2y, cx + 30, cy, palette.secLight, 0.7);
        ctx.globalAlpha = 1;

        drawText(label, "The streams converge…");
      } else {
        // Final — hybrid plasma + exchange sketch orbiting
        const pulse = 1 + Math.sin(t * 2) * 0.1;
        drawOrb(cx, cy, 22 * pulse, [
          "#ffffff",
          palette.orangeMain,
          palette.mix,
          palette.secMain,
          "transparent",
        ]);
        drawRays(cx, cy, 80, 26, t, palette.orangeMain, palette.secLight, palette.orangeDark, 1, 1.3);
        drawRays(cx, cy, 60, 18, t + 3, palette.secMain, palette.orangeSpark, palette.secDark, 0.8, 1.0);

        // Exchange labels appear progressively during the final 10s
        const reveal = clamp01((elapsed - 46) / 8);
        drawExchangeSketch(cx, cy, t, reveal);

        drawText("OmniBus 0day", `Orange + ${palette.secMain.toUpperCase()} = Evolution #${cycle + 1}`);
      }

      // Cățeluși — mereu deasupra, patrulează la marginea de jos
      updateAndDrawPuppies(dt);

      ctx.shadowBlur = 0;
      ctx.fillStyle = "#6b7280";
      ctx.font = "11px monospace";
      ctx.textAlign = "right";
      ctx.fillText(`cycle=${cycle + 1}  t=${elapsed.toFixed(1)}s`, W - 16, H - 16);

      raf = requestAnimationFrame(draw);
    };

    raf = requestAnimationFrame(draw);
    return () => cancelAnimationFrame(raf);
  }, []);

  return (
    <div className="max-w-6xl mx-auto px-3 sm:px-4 py-4 sm:py-8">
      <h1 className="text-lg sm:text-2xl font-bold text-mempool-text mb-2">0day — Evolution Flow</h1>
      <p className="text-mempool-text-dim text-sm mb-6">
        Visual origin story: a yellow seed awakens into orange plasma, a colored spark splits and
        converges, forging the OmniBus hybrid. Each cycle generates a new color mutation.
        Lightning strikes, meteor showers, floating ★ stars and ♥ hearts orbit the scene.
        At the apex, exchange partners orbit as a living sketch.
      </p>
      <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev overflow-hidden flex justify-center">
        <canvas
          ref={canvasRef}
          style={{ width: 960, height: 540, maxWidth: "100%" }}
        />
      </div>
      <div className="mt-4 text-xs text-mempool-text-dim space-y-1">
        <p>
          <span className="font-semibold text-mempool-text">Stage 1 (0-6s):</span> Yellow orb pulses — the seed.
        </p>
        <p>
          <span className="font-semibold text-mempool-text">Stage 2 (6-16s):</span> Orange plasma awakens from the seed.
        </p>
        <p>
          <span className="font-semibold text-mempool-text">Stage 3 (16-26s):</span> Random spark emerges and becomes plasma.
        </p>
        <p>
          <span className="font-semibold text-mempool-text">Stage 4 (26-36s):</span> Plasma splits into two streams.
        </p>
        <p>
          <span className="font-semibold text-mempool-text">Stage 5 (36-46s):</span> Convergence — streams merge with orange.
        </p>
        <p>
          <span className="font-semibold text-mempool-text">Stage 6 (46-56s):</span> Hybrid plasma stabilizes — orange traces remain.
          Exchange sketch (LCX, Kraken, Coinbase, Binance, Bybit, OKX, Gate.io, KuCoin, MEXC, Bitget, Electric Fonts, Lugn) orbits the core.
        </p>
        <p className="text-amber-400 pt-1">
          ∞ Loop — every cycle rolls a new color mutation (100+ variants).
        </p>
      </div>
    </div>
  );
}

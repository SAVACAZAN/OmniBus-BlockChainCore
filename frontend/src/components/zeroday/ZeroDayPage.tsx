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

    const draw = () => {
      const now = performance.now();
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
    <div className="max-w-6xl mx-auto px-4 py-8">
      <h1 className="text-2xl font-bold text-mempool-text mb-2">0day — Evolution Flow</h1>
      <p className="text-mempool-text-dim text-sm mb-6">
        Visual origin story: a yellow seed awakens into orange plasma, a colored spark splits and
        converges, forging the OmniBus hybrid. Each cycle generates a new color mutation.
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

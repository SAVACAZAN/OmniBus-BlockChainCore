import { useEffect, useRef } from "react";

interface Particle {
  x: number;
  y: number;
  vx: number;
  vy: number;
  life: number;
  maxLife: number;
  size: number;
  hue: number;
}

const EXCHANGE_LABELS = [
  "LCX", "Kraken", "Coinbase", "Binance", "Bybit",
  "OKX", "Gate.io", "KuCoin", "MEXC", "Bitget",
  "Electric Fonts", "Lugn",
];

export function DashboardPlasma() {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    let W = 0;
    let H = 0;
    let dpr = 1;
    let raf = 0;

    const ORANGE = { main: "#ff7f50", dark: "#ff4500", spark: "#ffffff" };
    let particles: Particle[] = [];
    let time = 0;
    let totalAbsorbed = 0;
    let labelReveal = 0; // 0..1 progres apariție etichete

    function resize() {
      const parent = canvas!.parentElement;
      if (!parent) return;
      W = parent.clientWidth;
      H = parent.clientHeight;
      dpr = window.devicePixelRatio || 1;
      canvas!.width = W * dpr;
      canvas!.height = H * dpr;
      ctx!.setTransform(dpr, 0, 0, dpr, 0, 0);
    }

    resize();
    const ro = new ResizeObserver(resize);
    ro.observe(canvas.parentElement!);

    function spawnParticle() {
      const margin = 20;
      const x = margin + Math.random() * (W - margin * 2);
      const y = margin + Math.random() * (H - margin * 2);
      const size = 2 + Math.random() * 4;
      const maxLife = 120 + Math.random() * 180;
      particles.push({
        x,
        y,
        vx: (Math.random() - 0.5) * 0.5,
        vy: (Math.random() - 0.5) * 0.5,
        life: 0,
        maxLife,
        size,
        hue: 80 + Math.random() * 80,
      });
    }

    function drawOrb(cx: number, cy: number, r: number, colors: string[]) {
      const grad = ctx!.createRadialGradient(cx, cy, r * 0.1, cx, cy, r);
      colors.forEach((c, i) => grad.addColorStop(i / (colors.length - 1), c));
      ctx!.fillStyle = grad;
      ctx!.beginPath();
      ctx!.arc(cx, cy, r, 0, Math.PI * 2);
      ctx!.fill();
    }

    function drawRays(cx: number, cy: number, baseLen: number, numRays: number, t: number, colorMain: string, colorSpark: string, shadowColor: string, alpha: number) {
      ctx!.globalAlpha = alpha;
      for (let i = 0; i < numRays; i++) {
        const angle = (i / numRays) * Math.PI * 2;
        const len = baseLen + Math.sin(t + i) * 4;
        ctx!.beginPath();
        ctx!.lineWidth = 0.6 + Math.random() * 1;
        ctx!.strokeStyle = Math.random() > 0.2 ? colorMain : colorSpark;
        ctx!.shadowBlur = 8;
        ctx!.shadowColor = shadowColor;
        let lx = cx;
        let ly = cy;
        for (let j = 0; j < 4; j++) {
          const seg = len / 4;
          const nx = cx + Math.cos(angle) * (j + 1) * seg + (Math.random() - 0.5) * 6;
          const ny = cy + Math.sin(angle) * (j + 1) * seg + (Math.random() - 0.5) * 6;
          ctx!.moveTo(lx, ly);
          ctx!.lineTo(nx, ny);
          lx = nx;
          ly = ny;
        }
        ctx!.stroke();
      }
      ctx!.shadowBlur = 0;
      ctx!.globalAlpha = 1;
    }

    function lerp(a: number, b: number, t: number) {
      return a + (b - a) * t;
    }

    function drawSketchyLine(x1: number, y1: number, x2: number, y2: number, color: string, width = 1) {
      ctx!.strokeStyle = color;
      ctx!.lineWidth = width;
      ctx!.beginPath();
      const steps = 10;
      for (let i = 0; i <= steps; i++) {
        const t = i / steps;
        const nx = lerp(x1, x2, t) + (Math.random() - 0.5) * 3;
        const ny = lerp(y1, y2, t) + (Math.random() - 0.5) * 3;
        if (i === 0) ctx!.moveTo(nx, ny);
        else ctx!.lineTo(nx, ny);
      }
      ctx!.stroke();
    }

    function drawExchangeSketch(cx: number, cy: number, t: number, reveal: number) {
      const count = EXCHANGE_LABELS.length;
      const radius = Math.min(W, H) * 0.42 + Math.sin(t * 0.5) * 8;
      const rotation = t * 0.25;

      ctx!.textAlign = "center";
      ctx!.textBaseline = "middle";

      for (let i = 0; i < count; i++) {
        const frac = i / count;
        const angle = frac * Math.PI * 2 + rotation;
        const tx = cx + Math.cos(angle) * radius;
        const ty = cy + Math.sin(angle) * radius;

        const itemReveal = Math.max(0, Math.min(1, (reveal - frac * 0.4) / 0.2));
        if (itemReveal <= 0) continue;

        const alpha = itemReveal;
        const sx = lerp(cx, tx, itemReveal);
        const sy = lerp(cy, ty, itemReveal);

        // Linie sketchy de la centru spre etichetă
        if (itemReveal > 0.3) {
          ctx!.globalAlpha = alpha * 0.3;
          drawSketchyLine(cx + Math.cos(angle) * 8, cy + Math.sin(angle) * 8, sx, sy, ORANGE.main, 0.7);
        }

        // Cerc mic sketchy
        ctx!.globalAlpha = alpha * 0.15;
        ctx!.strokeStyle = `hsl(${80 + i * 20}, 70%, 60%)`;
        ctx!.lineWidth = 0.8;
        ctx!.beginPath();
        for (let a = 0; a < Math.PI * 2; a += 0.5) {
          const rr = 14 + Math.random() * 2;
          const px = sx + Math.cos(a) * rr;
          const py = sy + Math.sin(a) * rr;
          if (a === 0) ctx!.moveTo(px, py); else ctx!.lineTo(px, py);
        }
        ctx!.closePath();
        ctx!.stroke();

        // Text
        ctx!.globalAlpha = alpha;
        ctx!.fillStyle = i % 2 === 0 ? "#d1d5db" : `hsl(${80 + i * 15}, 70%, 70%)`;
        ctx!.font = `${i % 3 === 0 ? "italic " : ""}11px "Courier New", monospace`;
        ctx!.fillText(EXCHANGE_LABELS[i], sx, sy);

        // Sub-linie
        ctx!.globalAlpha = alpha * 0.4;
        ctx!.strokeStyle = ORANGE.dark;
        ctx!.lineWidth = 0.5;
        const tw = ctx!.measureText(EXCHANGE_LABELS[i]).width;
        ctx!.beginPath();
        ctx!.moveTo(sx - tw / 2, sy + 9);
        ctx!.lineTo(sx + tw / 2, sy + 9);
        ctx!.stroke();
      }
      ctx!.globalAlpha = 1;
    }

    const draw = () => {
      time += 0.02;

      ctx!.clearRect(0, 0, W, H);

      // Sfera orange mare în stânga
      const ox = W * 0.5;
      const oy = H * 0.5;
      const or = Math.min(W, H) * 0.11;
      const pulse = 1 + Math.sin(time * 2) * 0.08;

      drawOrb(ox, oy, or * pulse, ["#ffffff", ORANGE.main, ORANGE.dark, "transparent"]);
      // Orange rays dominate — many, full-length, opaque. This is the
      // primary visual character. 36 rays gives a dense flame look without
      // turning into a solid disc.
      drawRays(ox, oy, or * 2.4, 36, time, ORANGE.main, ORANGE.spark, ORANGE.dark, 0.9);
      // Green secondary rays — short accent only. Half the length, fewer
      // count, lower alpha so they read as "color hints" mixed into the
      // orange flame, not as separate spikes pulling the eye away.
      drawRays(ox, oy, or * 1.9, 10, time * 0.6, "#00ff9a", "#aaffd4", "#00b370", 0.55);

      // Spawn particule noi
      if (particles.length < 40 && Math.random() > 0.7) {
        spawnParticle();
      }

      let absorbedThisFrame = 0;

      // Update & draw particule
      for (let i = particles.length - 1; i >= 0; i--) {
        const p = particles[i];
        p.life++;

        const dx = ox - p.x;
        const dy = oy - p.y;
        const dist = Math.hypot(dx, dy);
        const attraction = dist > or ? 0.03 : -0.01;
        p.vx += (dx / dist) * attraction;
        p.vy += (dy / dist) * attraction;
        p.vx *= 0.98;
        p.vy *= 0.98;
        p.vx += (Math.random() - 0.5) * 0.3;
        p.vy += (Math.random() - 0.5) * 0.3;

        p.x += p.vx;
        p.y += p.vy;

        const lifeRatio = p.life / p.maxLife;
        const alpha = lifeRatio < 0.2 ? lifeRatio / 0.2 : lifeRatio > 0.8 ? (1 - lifeRatio) / 0.2 : 1;

        if (dist < or * 0.5) {
          p.life = p.maxLife;
          absorbedThisFrame++;
        }

        if (p.life >= p.maxLife) {
          particles.splice(i, 1);
          continue;
        }

        const color = `hsl(${p.hue}, 80%, 55%)`;
        const colorLight = `hsl(${p.hue}, 70%, 75%)`;
        const colorDark = `hsl(${p.hue}, 90%, 35%)`;
        ctx!.globalAlpha = alpha * 0.7;
        const pr = p.size * (1 + Math.sin(time * 3 + i) * 0.2);
        drawOrb(p.x, p.y, pr, [colorLight, color, colorDark, "transparent"]);

        if (dist > or && Math.random() > 0.5) {
          ctx!.strokeStyle = color;
          ctx!.lineWidth = 0.4;
          ctx!.beginPath();
          ctx!.moveTo(p.x, p.y);
          ctx!.lineTo(p.x - p.vx * 4, p.y - p.vy * 4);
          ctx!.stroke();
        }
      }
      ctx!.globalAlpha = 1;

      totalAbsorbed += absorbedThisFrame;

      // Glow extra în funcție de particule aproape
      const nearCount = particles.filter(p => Math.hypot(ox - p.x, oy - p.y) < or * 0.8).length;
      if (nearCount > 0) {
        ctx!.globalAlpha = nearCount * 0.015;
        drawOrb(ox, oy, or * 1.3, [ORANGE.main, "transparent"]);
        ctx!.globalAlpha = 1;
      }

      // Afișare exchange labels după ce s-au absorbit destule particule
      const targetReveal = Math.min(1, totalAbsorbed / 15);
      labelReveal += (targetReveal - labelReveal) * 0.02;
      if (labelReveal > 0.05) {
        drawExchangeSketch(ox, oy, time, labelReveal);
      }

      // Reset periodic ca să reînceapă ciclul
      if (totalAbsorbed > 50 && labelReveal > 0.95 && particles.length === 0) {
        totalAbsorbed = 0;
        labelReveal = 0;
      }

      raf = requestAnimationFrame(draw);
    };

    raf = requestAnimationFrame(draw);
    return () => {
      cancelAnimationFrame(raf);
      ro.disconnect();
    };
  }, []);

  return (
    <canvas
      ref={canvasRef}
      className="absolute inset-0 w-full h-full pointer-events-none"
      style={{ zIndex: 1 }}
    />
  );
}

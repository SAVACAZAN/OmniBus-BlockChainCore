import { useEffect, useRef } from "react";

import { useIsPlasmaActive } from "./PlasmaSlotContext";

interface PlasmaLogoOrangeProps {
  size?: number;
  className?: string;
}

export function PlasmaLogoOrange({ size = 40, className = "", slotIndex }: PlasmaLogoOrangeProps & { slotIndex?: number }) {
  // Hooks unconditionally first (Rules of Hooks).
  const isActive = useIsPlasmaActive(slotIndex ?? -1);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const visible = !(slotIndex !== undefined && !isActive);

  useEffect(() => {
    if (!visible) return;
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    const dpr = window.devicePixelRatio || 1;
    canvas.width = size * dpr;
    canvas.height = size * dpr;
    ctx.scale(dpr, dpr);

    let time = 0;
    let raf = 0;

    const draw = () => {
      ctx.clearRect(0, 0, size, size);
      const cx = size / 2;
      const cy = size / 2;
      const numRays = 22;

      time += 0.05;

      const scale = size / 200;

      for (let i = 0; i < numRays; i++) {
        const angle = (i / numRays) * Math.PI * 2;
        const baseLen = (35 + Math.sin(time + i) * 10) * scale;

        ctx.beginPath();
        ctx.lineWidth = 0.8 + Math.random() * 1.2;
        ctx.strokeStyle = Math.random() > 0.1 ? "#ff7f50" : "#00ff88";
        ctx.shadowBlur = 8;
        ctx.shadowColor = "#ff4500";

        let lx = cx;
        let ly = cy;

        for (let j = 0; j < 5; j++) {
          const segmentLen = baseLen / 5;
          const nextLx = cx + Math.cos(angle) * (j + 1) * segmentLen + (Math.random() - 0.5) * 6 * scale;
          const nextLy = cy + Math.sin(angle) * (j + 1) * segmentLen + (Math.random() - 0.5) * 6 * scale;
          ctx.moveTo(lx, ly);
          ctx.lineTo(nextLx, nextLy);
          lx = nextLx;
          ly = nextLy;
        }
        ctx.stroke();

        ctx.beginPath();
        ctx.arc(lx, ly, Math.random() * 1.5 * scale, 0, Math.PI * 2);
        ctx.fillStyle = "white";
        ctx.fill();
      }

      const innerR = 2 * scale;
      const outerR = 12 * scale;
      const hue = (time * 60) % 360;
      const gradient = ctx.createRadialGradient(cx, cy, innerR, cx, cy, outerR);
      gradient.addColorStop(0, `hsl(${hue}, 100%, 80%)`);
      gradient.addColorStop(0.35, `hsl(${(hue + 90) % 360}, 100%, 60%)`);
      gradient.addColorStop(0.7, `hsl(${(hue + 200) % 360}, 100%, 50%)`);
      gradient.addColorStop(1, "transparent");
      ctx.fillStyle = gradient;
      ctx.beginPath();
      ctx.arc(cx, cy, (10 + Math.sin(time * 2) * 2.5) * scale, 0, Math.PI * 2);
      ctx.fill();

      raf = requestAnimationFrame(draw);
    };

    draw();
    return () => cancelAnimationFrame(raf);
  }, [size, visible]);

  if (!visible) {
    return <div style={{ width: size, height: size }} className={className} />;
  }

  return (
    <canvas
      ref={canvasRef}
      style={{ width: size, height: size, filter: "blur(0.4px) contrast(1.2)" }}
      className={className}
    />
  );
}

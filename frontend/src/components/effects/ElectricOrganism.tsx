import { useEffect, useRef } from "react";

interface ElectricOrganismProps {
  size?: number;
  className?: string;
}

export function ElectricOrganism({ size = 130, className = "" }: ElectricOrganismProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
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
        const baseLen = (70 + Math.sin(time + i) * 20) * scale;

        ctx.beginPath();
        ctx.lineWidth = (1.5 + Math.random() * 2) * scale;
        ctx.strokeStyle = Math.random() > 0.1 ? "#ff7f50" : "#ffffff";
        ctx.shadowBlur = 15 * scale;
        ctx.shadowColor = "#ff4500";

        let lx = cx;
        let ly = cy;

        for (let j = 0; j < 5; j++) {
          const segmentLen = baseLen / 5;
          const nextLx = cx + Math.cos(angle) * (j + 1) * segmentLen + (Math.random() - 0.5) * 15 * scale;
          const nextLy = cy + Math.sin(angle) * (j + 1) * segmentLen + (Math.random() - 0.5) * 15 * scale;
          ctx.moveTo(lx, ly);
          ctx.lineTo(nextLx, nextLy);
          lx = nextLx;
          ly = nextLy;
        }
        ctx.stroke();

        // Particule la capătul razelor
        ctx.beginPath();
        ctx.arc(lx, ly, Math.random() * 3 * scale, 0, Math.PI * 2);
        ctx.fillStyle = "white";
        ctx.fill();
      }

      // Nucleul central (plasmă)
      const innerR = 5 * scale;
      const outerR = 25 * scale;
      const gradient = ctx.createRadialGradient(cx, cy, innerR, cx, cy, outerR);
      gradient.addColorStop(0, "white");
      gradient.addColorStop(0.4, "#ff7f50");
      gradient.addColorStop(1, "transparent");
      ctx.fillStyle = gradient;
      ctx.beginPath();
      ctx.arc(cx, cy, (20 + Math.sin(time * 2) * 5) * scale, 0, Math.PI * 2);
      ctx.fill();

      raf = requestAnimationFrame(draw);
    };

    draw();
    return () => cancelAnimationFrame(raf);
  }, [size]);

  return (
    <canvas
      ref={canvasRef}
      style={{ width: size, height: size, filter: "blur(0.5px) contrast(1.2)" }}
      className={className}
    />
  );
}

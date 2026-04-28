import { useEffect, useRef } from "react";

interface MatrixRainProps {
  width?: number;
  height?: number;
  className?: string;
}

export function MatrixRain({ width = 80, height = 120, className = "" }: MatrixRainProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    const dpr = window.devicePixelRatio || 1;
    canvas.width = width * dpr;
    canvas.height = height * dpr;
    ctx.scale(dpr, dpr);

    const drops: number[] = Array(Math.floor(width / 10)).fill(0);

    let raf = 0;

    const draw = () => {
      ctx.fillStyle = "rgba(10, 10, 10, 0.15)";
      ctx.fillRect(0, 0, width, height);
      ctx.fillStyle = "#ff6b3d";
      ctx.font = "10px monospace";

      drops.forEach((y, i) => {
        ctx.fillText(Math.floor(Math.random() * 2).toString(), i * 10, y);
        if (y > height && Math.random() > 0.98) {
          drops[i] = 0;
        } else {
          drops[i] += 10;
        }
      });

      raf = requestAnimationFrame(draw);
    };

    draw();
    return () => cancelAnimationFrame(raf);
  }, [width, height]);

  return (
    <canvas
      ref={canvasRef}
      style={{ width, height, opacity: 0.35, filter: "blur(0.5px)" }}
      className={className}
    />
  );
}

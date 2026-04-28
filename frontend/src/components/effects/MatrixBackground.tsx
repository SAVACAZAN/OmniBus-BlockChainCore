import { useEffect, useRef } from "react";

interface MatrixBackgroundProps {
  opacity?: number;
  color?: string;
}

export function MatrixBackground({ opacity = 0.35, color = "#ff6b3d" }: MatrixBackgroundProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    let w = 0;
    let h = 0;
    let drops: number[] = [];

    const resize = () => {
      w = canvas.width = window.innerWidth;
      h = canvas.height = window.innerHeight;
      drops = Array(Math.floor(w / 15)).fill(0);
    };
    resize();
    window.addEventListener("resize", resize);

    let raf = 0;
    let last = 0;

    const draw = (now: number) => {
      // throttle to ~30fps to keep CPU low under main UI
      if (now - last >= 33) {
        ctx.fillStyle = "rgba(10, 10, 10, 0.1)";
        ctx.fillRect(0, 0, w, h);
        ctx.fillStyle = color;
        ctx.font = "12px monospace";
        for (let i = 0; i < drops.length; i++) {
          const y = drops[i];
          ctx.fillText(String(Math.floor(Math.random() * 2)), i * 15, y);
          if (y > h && Math.random() > 0.98) drops[i] = 0;
          else drops[i] += 15;
        }
        last = now;
      }
      raf = requestAnimationFrame(draw);
    };
    raf = requestAnimationFrame(draw);

    return () => {
      cancelAnimationFrame(raf);
      window.removeEventListener("resize", resize);
    };
  }, [color]);

  return (
    <canvas
      ref={canvasRef}
      style={{
        position: "fixed",
        top: 0,
        left: 0,
        width: "100%",
        height: "100%",
        zIndex: 0,
        opacity,
        filter: "blur(1px)",
        pointerEvents: "none",
      }}
      aria-hidden="true"
    />
  );
}

import { useEffect, useRef, useState } from "react";

// Load Swagger UI from CDN
function loadScript(src: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const existing = document.querySelector(`script[src="${src}"]`);
    if (existing) { resolve(); return; }
    const script = document.createElement("script");
    script.src = src;
    script.onload = () => resolve();
    script.onerror = () => reject(new Error(`Failed to load ${src}`));
    document.head.appendChild(script);
  });
}

function loadLink(href: string, rel = "stylesheet"): Promise<void> {
  return new Promise((resolve) => {
    const existing = document.querySelector(`link[href="${href}"]`);
    if (existing) { resolve(); return; }
    const link = document.createElement("link");
    link.rel = rel;
    link.href = href;
    link.onload = () => resolve();
    link.onerror = () => resolve();
    document.head.appendChild(link);
  });
}

declare global {
  interface Window {
    SwaggerUIBundle?: any;
    SwaggerUIStandalonePreset?: any;
    __omnibusSwaggerInstance?: any;
  }
}

type Mode = "real" | "paper";

// We rewrite the swagger.json on the fly so the path prefix matches
// the selected mode. Real → /exchange/0/...  Paper → /paper/0/...
// Server-side both prefixes are routed through dispatchRest, with
// the paper engine + OMNI_DEMO token isolated from the real engine.
async function buildSpec(mode: Mode): Promise<any> {
  const r = await fetch("/swagger.json");
  if (!r.ok) throw new Error(`swagger.json fetch failed (${r.status})`);
  const spec = await r.json();

  if (mode === "paper") {
    const newPaths: Record<string, any> = {};
    for (const [path, ops] of Object.entries(spec.paths || {})) {
      const swapped = path.replace(/^\/exchange\/0\//, "/paper/0/");
      newPaths[swapped] = ops;
    }
    spec.paths = newPaths;
    spec.info = {
      ...spec.info,
      title: (spec.info?.title || "OmniBus Exchange API") + " (Paper)",
      description:
        (spec.info?.description || "") +
        "\n\n**Paper-trader mode active.** All endpoints below route through " +
        "the demo matching engine. Settlement token is OMNI_DEMO; real " +
        "balances and orders are not affected.",
    };
  }

  return spec;
}

export function ApiDocsPage() {
  const containerRef = useRef<HTMLDivElement>(null);
  const [mode, setMode] = useState<Mode>(() => {
    return (localStorage.getItem("omnibus.api.mode") as Mode) || "real";
  });

  useEffect(() => {
    localStorage.setItem("omnibus.api.mode", mode);
  }, [mode]);

  useEffect(() => {
    let destroyed = false;

    async function init() {
      await loadLink("https://unpkg.com/swagger-ui-dist@5.11.0/swagger-ui.css");
      await loadScript("https://unpkg.com/swagger-ui-dist@5.11.0/swagger-ui-bundle.js");
      await loadScript("https://unpkg.com/swagger-ui-dist@5.11.0/swagger-ui-standalone-preset.js");
      if (destroyed || !containerRef.current || !window.SwaggerUIBundle) return;

      const spec = await buildSpec(mode);
      if (destroyed) return;

      // Clear any prior render so toggling mode rebuilds the docs.
      if (containerRef.current) containerRef.current.innerHTML = "";

      window.__omnibusSwaggerInstance = window.SwaggerUIBundle({
        spec,
        dom_id: "#swagger-ui-container",
        deepLinking: true,
        presets: [
          window.SwaggerUIBundle.presets.apis,
          window.SwaggerUIStandalonePreset,
        ],
        plugins: [window.SwaggerUIBundle.plugins.DownloadUrl],
        layout: "StandaloneLayout",
        validatorUrl: null,
        supportedSubmitMethods: ["get", "post", "put", "delete", "patch"],
        onComplete: () => {
          // Dark mode tweaks (idempotent — repeated mounts keep the same style tag).
          const id = "omnibus-swagger-dark";
          if (document.getElementById(id)) return;
          const style = document.createElement("style");
          style.id = id;
          style.textContent = `
            .swagger-ui { filter: invert(1) hue-rotate(180deg); }
            .swagger-ui .highlight-code { filter: invert(1) hue-rotate(180deg); }
            .swagger-ui svg { filter: invert(1) hue-rotate(180deg); }
            .swagger-ui .topbar { display: none; }
          `;
          document.head.appendChild(style);
        },
      });
    }

    init();
    return () => { destroyed = true; };
  }, [mode]);

  const baseUrl = "https://omnibusblockchain.cc:8443";
  const prefix = mode === "real" ? "/exchange/0/" : "/paper/0/";

  return (
    <div className="max-w-7xl mx-auto px-4 py-6">
      <div className="mb-4">
        <div className="flex items-center justify-between flex-wrap gap-3">
          <div>
            <h1 className="text-2xl font-bold text-mempool-text">Exchange API Docs</h1>
            <p className="text-sm text-mempool-text-dim mt-1">
              Kraken-compatible Spot REST API for the OmniBus native DEX.
              Base URL: <code className="text-mempool-blue font-mono">{baseUrl}{prefix}…</code>
            </p>
          </div>
          {/* Mode toggle: rewrites swagger paths in-flight between
              /exchange/0/* (real) and /paper/0/* (paper-trader). The
              server routes the two prefixes to isolated matching
              engines + balance pools (OMNI_DEMO token suffix on paper
              side). Persisted to localStorage so a reload remembers
              the operator's last choice. */}
          <div className="flex items-center gap-1 p-1 rounded-lg border border-mempool-border bg-mempool-bg">
            <button
              onClick={() => setMode("real")}
              className={`px-3 py-1.5 text-xs font-semibold rounded transition-colors ${
                mode === "real"
                  ? "bg-mempool-green text-black"
                  : "text-mempool-text-dim hover:text-mempool-text"
              }`}
            >
              REAL
            </button>
            <button
              onClick={() => setMode("paper")}
              className={`px-3 py-1.5 text-xs font-semibold rounded transition-colors ${
                mode === "paper"
                  ? "bg-mempool-orange text-black"
                  : "text-mempool-text-dim hover:text-mempool-text"
              }`}
            >
              PAPER
            </button>
          </div>
        </div>
        <div className="mt-2 flex gap-3 text-xs flex-wrap">
          <span className={`px-2 py-1 rounded ${mode === "real" ? "bg-mempool-green/20 text-mempool-green" : "bg-mempool-orange/20 text-mempool-orange"}`}>
            {mode === "real" ? "REAL · OMNI / BTC / ETH / LCX / USDC" : "PAPER · OMNI_DEMO settlement"}
          </span>
          <span className="px-2 py-1 rounded bg-mempool-blue/20 text-mempool-blue">48 Endpoints</span>
          <span className="px-2 py-1 rounded bg-mempool-text-dim/20 text-mempool-text-dim">
            Path prefix: <code>{prefix}</code>
          </span>
        </div>
      </div>
      <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev overflow-hidden">
        <div id="swagger-ui-container" ref={containerRef} style={{ minHeight: 800 }} />
      </div>
    </div>
  );
}

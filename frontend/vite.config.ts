import { defineConfig, loadEnv } from "vite";
import react from "@vitejs/plugin-react";

// VITE_RPC_HOST = backend host (default localhost — for local dev).
// Pe VPS pornesc cu VITE_RPC_HOST=127.0.0.1 ca proxy-ul sa loveasca nodurile pe loopback.
// Dintr-un browser pe Windows local, deschizi http://38.143.19.97:8888 — Vite pe VPS face proxy.
//
// Porturile per chain sunt din chain_config.zig:
//   mainnet: rpc=8332, ws=8334
//   testnet: rpc=18332, ws=18334
//   regtest: rpc=28332, ws=28334
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), "");
  const host = env.VITE_RPC_HOST || "127.0.0.1";

  return {
    plugins: [react()],
    server: {
      port: 8888,
      host: "0.0.0.0",
      strictPort: false,
      proxy: {
        // IMPORTANT: order matters — Vite's micromatch matches first key that fits.
        // Use regex anchors (`^/api-mainnet$` etc.) so "/api" can't shadow "/api-testnet".
        "^/api-mainnet$": {
          target: `http://${host}:8332`,
          changeOrigin: true,
          rewrite: () => "",
        },
        "^/api-testnet$": {
          target: `http://${host}:18332`,
          changeOrigin: true,
          rewrite: () => "",
        },
        "^/api-regtest$": {
          target: `http://${host}:28332`,
          changeOrigin: true,
          rewrite: () => "",
        },
        // Legacy `/api` (no chain suffix) — still defaults to mainnet.
        // Anchored so it cannot accidentally swallow "/api-testnet".
        "^/api$": {
          target: `http://${host}:8332`,
          changeOrigin: true,
          rewrite: () => "",
        },
        // WebSocket per chain — anchored regex too.
        "^/ws-mainnet$": {
          target: `ws://${host}:8334`,
          ws: true,
          changeOrigin: true,
          rewrite: () => "",
        },
        "^/ws-testnet$": {
          target: `ws://${host}:18334`,
          ws: true,
          changeOrigin: true,
          rewrite: () => "",
        },
        "^/ws-regtest$": {
          target: `ws://${host}:28334`,
          ws: true,
          changeOrigin: true,
          rewrite: () => "",
        },
      },
    },
    build: {
      outDir: "dist",
      sourcemap: false,
      minify: "esbuild",
    },
  };
});

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
      // Vite 4 uses string array for allowedHosts. Vite 5+ accepts "all".
      // We list every variant we proxy through Nginx + the special "all"
      // string which some Vite 4 minor versions also accept.
      allowedHosts: [
        "all",
        "localhost",
        "127.0.0.1",
        "38.143.19.97",
        "omnibusblockchain.cc",
        "www.omnibusblockchain.cc",
        ".omnibusblockchain.cc",
      ] as any,
      proxy: {
        // SPECIFIC paths first (longer / chain-suffixed) so they match before
        // the generic /api alias. Vite/http-proxy iterates keys in declared
        // order and first match wins. The legacy "/api" stays last.
        "/api-mainnet": {
          target: `http://${host}:8332`,
          changeOrigin: true,
          rewrite: (p) => p.replace(/^\/api-mainnet/, ""),
        },
        "/api-testnet": {
          target: `http://${host}:18332`,
          changeOrigin: true,
          rewrite: (p) => p.replace(/^\/api-testnet/, ""),
        },
        "/api-regtest": {
          target: `http://${host}:28332`,
          changeOrigin: true,
          rewrite: (p) => p.replace(/^\/api-regtest/, ""),
        },
        "/ws-mainnet": {
          target: `ws://${host}:8334`,
          ws: true,
          changeOrigin: true,
          rewrite: (p) => p.replace(/^\/ws-mainnet/, ""),
        },
        "/ws-testnet": {
          target: `ws://${host}:18334`,
          ws: true,
          changeOrigin: true,
          rewrite: (p) => p.replace(/^\/ws-testnet/, ""),
        },
        "/ws-regtest": {
          target: `ws://${host}:28334`,
          ws: true,
          changeOrigin: true,
          rewrite: (p) => p.replace(/^\/ws-regtest/, ""),
        },
        // Legacy "/api" (no suffix) — defaults to mainnet. MUST be LAST so the
        // chain-suffixed routes above are tried first.
        "/api": {
          target: `http://${host}:8332`,
          changeOrigin: true,
          rewrite: (p) => p.replace(/^\/api/, ""),
        },
      },
    },
    // Vite 4 doesn't resolve ESM subpath exports with .js suffix without
    // explicit pre-bundling. Force esbuild to include these so the dev
    // server can find @noble/post-quantum's submodules.
    optimizeDeps: {
      include: [
        "@noble/post-quantum/ml-dsa.js",
        "@noble/post-quantum/falcon.js",
        "@noble/post-quantum/slh-dsa.js",
      ],
    },
    build: {
      outDir: "dist",
      sourcemap: false,
      minify: "esbuild",
    },
  };
});

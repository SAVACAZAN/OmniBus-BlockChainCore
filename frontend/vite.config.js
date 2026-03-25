import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
export default defineConfig({
    plugins: [react()],
    server: {
        port: 8888,
        strictPort: false,
        proxy: {
            "/api": {
                target: "http://localhost:8332",
                changeOrigin: true,
                rewrite: function (path) { return path.replace(/^\/api/, ""); },
            },
        },
    },
    build: {
        outDir: "dist",
        sourcemap: false,
        minify: "terser",
    },
});

/** @type {import('tailwindcss').Config} */
export default {
  content: ["./index.html", "./src/**/*.{js,ts,jsx,tsx}"],
  theme: {
    extend: {
      colors: {
        mempool: {
          bg: "#11131f",
          "bg-light": "#1a1d3a",
          card: "#1d2040",
          border: "#2a2d4a",
          blue: "#4a90d9",
          purple: "#7b61ff",
          green: "#00b3a4",
          orange: "#ff9500",
          red: "#ff4466",
          text: "#e0e0f0",
          "text-dim": "#8888aa",
        },
      },
      animation: {
        fadeIn: "fadeIn 0.3s ease-out",
        slideInRight: "slideInRight 0.5s ease-out",
        slideOutLeft: "slideOutLeft 0.5s ease-out",
        pulseGlow: "pulseGlow 2s ease-in-out infinite",
        fillIn: "fillIn 0.3s ease-out",
      },
      keyframes: {
        fadeIn: {
          "0%": { opacity: "0", transform: "translateY(8px)" },
          "100%": { opacity: "1", transform: "translateY(0)" },
        },
        slideInRight: {
          "0%": { opacity: "0", transform: "translateX(40px)" },
          "100%": { opacity: "1", transform: "translateX(0)" },
        },
        slideOutLeft: {
          "0%": { opacity: "1", transform: "translateX(0)" },
          "100%": { opacity: "0", transform: "translateX(-40px)" },
        },
        pulseGlow: {
          "0%, 100%": { boxShadow: "0 0 8px rgba(74,144,217,0.3)" },
          "50%": { boxShadow: "0 0 20px rgba(74,144,217,0.6)" },
        },
        fillIn: {
          "0%": { opacity: "0", transform: "scale(0.5)" },
          "100%": { opacity: "1", transform: "scale(1)" },
        },
      },
    },
  },
  plugins: [],
};

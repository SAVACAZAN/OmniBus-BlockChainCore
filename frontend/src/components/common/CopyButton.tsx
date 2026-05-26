import { useState } from "react";
import { Copy, Check } from "lucide-react";

interface Props {
  text: string;
  /** "icon" = small icon-only button (default). "button" = solid text button. */
  variant?: "icon" | "button";
  label?: string;
}

export function CopyButton({ text, variant = "icon", label = "Copy" }: Props) {
  const [copied, setCopied] = useState(false);

  const handle = () => {
    navigator.clipboard.writeText(text).catch(() => undefined);
    setCopied(true);
    window.setTimeout(() => setCopied(false), 1500);
  };

  if (variant === "button") {
    return (
      <button
        onClick={handle}
        className="bg-mempool-blue text-white px-3 py-1 rounded-lg text-xs font-semibold hover:opacity-90 active:scale-95 transition-transform"
      >
        {copied ? "Copied!" : label}
      </button>
    );
  }

  return (
    <button
      onClick={handle}
      title="Copy"
      className="ml-1 p-0.5 rounded text-mempool-text-dim hover:text-mempool-blue transition-colors"
    >
      {copied ? <Check className="w-3 h-3 text-mempool-green" /> : <Copy className="w-3 h-3" />}
    </button>
  );
}

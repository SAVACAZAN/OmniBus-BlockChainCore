export const KIND_STYLE: Record<string, string> = {
  coinbase:       "bg-yellow-500/20 text-yellow-300",
  faucet:         "bg-cyan-500/20 text-cyan-300",
  registrar:      "bg-purple-500/20 text-purple-300",
  exchange:       "bg-blue-500/20 text-blue-300",
  stake:          "bg-green-500/20 text-green-300",
  unstake:        "bg-amber-500/20 text-amber-300",
  ns_claim:       "bg-violet-500/20 text-violet-300",
  agent_register: "bg-indigo-500/20 text-indigo-300",
  notarize:       "bg-rose-500/20 text-rose-300",
  demo_grant:     "bg-pink-500/20 text-pink-300",
  transfer:       "bg-gray-700/40 text-gray-300",
};

export function KindBadge({ kind, memo, size = "sm" }: {
  kind?: string;
  memo?: string;
  size?: "xs" | "sm";
}) {
  if (!kind) return null;
  const cls = KIND_STYLE[kind] ?? "bg-gray-700/40 text-gray-300";
  const textCls = size === "xs" ? "text-[9px]" : "text-[10px]";
  return (
    <span
      className={`inline-block px-1.5 py-0 rounded ${textCls} uppercase tracking-wide font-mono flex-shrink-0 ${cls}`}
      title={memo || kind}
    >
      {kind}
    </span>
  );
}

export function SchemeTag({ scheme }: { scheme?: string | null }) {
  if (!scheme) return null;
  const isPQ = scheme.includes("ML-DSA") || scheme.includes("Falcon") || scheme.includes("SLH-DSA") || scheme.includes("Hybrid");
  const isSoulbound = scheme.includes("soulbound");
  const cls = isSoulbound
    ? "bg-purple-400/10 text-purple-300 border-purple-400/30"
    : isPQ
    ? "bg-blue-400/10 text-blue-300 border-blue-400/30"
    : "bg-green-400/10 text-green-300 border-green-400/30";
  return (
    <span className={`inline-block px-1.5 py-0 rounded border text-[10px] font-mono flex-shrink-0 ${cls}`}>
      {isPQ ? "🔒 " : "🔑 "}{scheme}
    </span>
  );
}

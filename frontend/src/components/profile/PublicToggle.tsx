/**
 * PublicToggle.tsx — reusable per-field visibility switch.
 *
 * Public  = "🌍 Public"  → field included in profile_get for anyone
 * Private = "🔒 Private" → field returned only to the owner viewing themselves
 *
 * The chain enforces this via a Merkle visibility mask; see `profile_update`.
 */

export type FieldVisibility = "public" | "private";

export function PublicToggle({
  value,
  onChange,
  disabled = false,
  size = "sm",
}: {
  value: FieldVisibility;
  onChange: (v: FieldVisibility) => void;
  disabled?: boolean;
  size?: "xs" | "sm";
}) {
  const isPublic = value === "public";
  const px = size === "xs" ? "px-1.5 py-0.5 text-[10px]" : "px-2 py-1 text-[11px]";
  return (
    <button
      type="button"
      onClick={() => !disabled && onChange(isPublic ? "private" : "public")}
      disabled={disabled}
      title={isPublic ? "Public — visible to anyone" : "Private — only you can see this"}
      className={`${px} rounded-full font-medium border transition-colors flex items-center gap-1 ${
        isPublic
          ? "bg-mempool-blue/15 border-mempool-blue/40 text-mempool-blue hover:bg-mempool-blue/25"
          : "bg-mempool-bg border-mempool-border text-mempool-text-dim hover:text-mempool-text"
      } ${disabled ? "opacity-60 cursor-not-allowed" : "cursor-pointer"}`}
    >
      <span>{isPublic ? "🌍" : "🔒"}</span>
      <span>{isPublic ? "Public" : "Private"}</span>
    </button>
  );
}

export function PublicBadge({ value }: { value: FieldVisibility }) {
  const isPublic = value === "public";
  return (
    <span
      className={`px-1.5 py-0.5 rounded-full text-[10px] font-medium border ${
        isPublic
          ? "bg-mempool-blue/15 border-mempool-blue/40 text-mempool-blue"
          : "bg-mempool-bg border-mempool-border text-mempool-text-dim"
      }`}
    >
      {isPublic ? "🌍 Public" : "🔒 Private"}
    </span>
  );
}

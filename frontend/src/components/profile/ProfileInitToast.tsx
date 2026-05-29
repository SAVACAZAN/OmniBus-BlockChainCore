import { useEffect, useState } from "react";
import { PROFILE_INIT_TOAST_EVENT, type ProfileInitToastDetail } from "../../api/wallet/profile-init";

/**
 * Listens for the `omnibus:profile-init-toast` window event and shows a
 * short-lived notice with the freshly-allocated DID. Mounted once at the
 * App root so any flow that creates a profile can fire-and-forget the
 * event without prop-drilling.
 */
export function ProfileInitToast({ onOpenProfile }: { onOpenProfile?: (address: string) => void }) {
  const [toast, setToast] = useState<ProfileInitToastDetail | null>(null);

  useEffect(() => {
    const handler = (e: Event) => {
      const detail = (e as CustomEvent<ProfileInitToastDetail>).detail;
      if (!detail) return;
      setToast(detail);
      window.setTimeout(() => setToast((cur) => (cur === detail ? null : cur)), 6000);
    };
    window.addEventListener(PROFILE_INIT_TOAST_EVENT, handler);
    return () => window.removeEventListener(PROFILE_INIT_TOAST_EVENT, handler);
  }, []);

  if (!toast) return null;

  return (
    <div className="fixed bottom-20 sm:bottom-6 right-4 z-[100] max-w-sm bg-mempool-bg-elev border border-mempool-blue/40 rounded-lg shadow-2xl p-3 backdrop-blur-md animate-fade-in">
      <div className="flex items-start gap-2">
        <span className="text-mempool-blue text-lg leading-none">★</span>
        <div className="flex-1 min-w-0">
          <div className="text-sm font-semibold text-mempool-text">
            OmniBus ID created
          </div>
          <div className="text-[11px] font-mono text-mempool-text-dim truncate">
            {toast.did}
          </div>
          {onOpenProfile && (
            <button
              onClick={() => { onOpenProfile(toast.address); setToast(null); }}
              className="mt-1 text-[11px] text-mempool-blue hover:underline"
            >
              Open profile →
            </button>
          )}
        </div>
        <button
          onClick={() => setToast(null)}
          className="text-mempool-text-dim hover:text-mempool-text text-xs leading-none"
          aria-label="Dismiss"
        >
          ×
        </button>
      </div>
    </div>
  );
}

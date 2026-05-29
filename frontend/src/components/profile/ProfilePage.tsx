/**
 * ProfilePage.tsx — 4-facet profile viewer / editor.
 *
 * Routing model: the host app uses tab-based navigation, not react-router.
 * We expose two entry points:
 *   - <ProfilePage /> with no props        → views the connected wallet
 *   - <ProfilePage address="ob1q…" />       → views the given address read-only
 *                                             (or editable if it matches wallet)
 *
 * The host can also pass `initialAddress` from a URL hash (`#/profile/<addr>`)
 * to support deep links without a router.
 */

import { useEffect, useState } from "react";
import { rpc, type ProfileFacet, type ProfileFull } from "../../api/clients/rpc-client";
import { useWallet } from "../../api/hooks/use-wallet";
import { initProfileForAddress } from "../../api/wallet/profile-init";
import {
  signProfileUpdatePayload,
  sha256dHex,
  stableStringify,
} from "../../api/sign/exchange-sign";
import { nextNonce } from "../../api/wallet/wallet-keystore";
import { SocialTab } from "./SocialTab";
import { ProfessionalTab } from "./ProfessionalTab";
import { CulturalTab } from "./CulturalTab";
import { EconomicTab } from "./EconomicTab";
import type { FieldVisibility } from "./PublicToggle";


type TabKey = ProfileFacet;

const TABS: { id: TabKey; label: string; emoji: string }[] = [
  { id: "social", label: "Social", emoji: "💬" },
  { id: "professional", label: "Professional", emoji: "💼" },
  { id: "cultural", label: "Cultural", emoji: "🎭" },
  { id: "economic", label: "Economic", emoji: "💰" },
];

export interface ProfilePageProps {
  /** Override address to view. Default = connected wallet. */
  address?: string;
}

export function ProfilePage({ address: addressProp }: ProfilePageProps = {}) {
  const wallet = useWallet();
  const viewedAddress = addressProp || wallet?.address || "";

  const [profile, setProfile] = useState<ProfileFull | null>(null);
  const [loading, setLoading] = useState(false);
  const [active, setActive] = useState<TabKey>("social");
  const [initBusy, setInitBusy] = useState(false);

  const editable = !!wallet && wallet.address === viewedAddress;

  const refresh = async (addr: string) => {
    if (!addr) return;
    setLoading(true);
    try {
      const p = await rpc.profileGet(addr);
      setProfile(p);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    if (viewedAddress) refresh(viewedAddress);
    else setProfile(null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [viewedAddress]);

  const handleInit = async () => {
    if (!viewedAddress || !editable) return;
    setInitBusy(true);
    try {
      await initProfileForAddress(viewedAddress);
      await refresh(viewedAddress);
    } finally {
      setInitBusy(false);
    }
  };

  const saveFacet = async (
    facet: ProfileFacet,
    fields: Record<string, unknown>,
    mask: Record<string, FieldVisibility>,
  ) => {
    if (!wallet || !viewedAddress) throw new Error("Wallet not connected");
    const nonce = nextNonce();
    const fieldsHash = sha256dHex(stableStringify(fields));
    const maskHash = sha256dHex(stableStringify(mask));
    const { signature, publicKey } = signProfileUpdatePayload({
      privateKeyHex: wallet.privateKey,
      address: viewedAddress,
      facet,
      fieldsHashHex: fieldsHash,
      maskHashHex: maskHash,
      nonce,
    });
    await rpc.profileUpdate({
      address: viewedAddress,
      facet,
      fields,
      visibility_mask: mask,
      nonce,
      signature,
      publicKey,
    });
    await refresh(viewedAddress);
  };

  if (!viewedAddress) {
    return (
      <div className="max-w-3xl mx-auto p-4 sm:p-6">
        <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-6 text-center text-sm text-mempool-text-dim">
          Connect a wallet to view or edit your OmniBus ID.
        </div>
      </div>
    );
  }

  return (
    <div className="max-w-3xl mx-auto p-3 sm:p-6 space-y-4">
      <ProfileHeader
        address={viewedAddress}
        profile={profile}
        editable={editable}
        loading={loading}
        onInit={handleInit}
        initBusy={initBusy}
      />

      {profile && (
        <>
          <TabBar active={active} onSelect={setActive} />

          <div className="rounded-xl border border-mempool-border bg-mempool-bg-elev p-4 sm:p-5">
            {active === "social" && (
              <SocialTab
                profile={profile}
                editable={editable}
                onSave={(f, m) => saveFacet("social", f as Record<string, unknown>, m)}
              />
            )}
            {active === "professional" && (
              <ProfessionalTab
                profile={profile}
                editable={editable}
                onSave={(f, m) => saveFacet("professional", f as Record<string, unknown>, m)}
              />
            )}
            {active === "cultural" && (
              <CulturalTab
                profile={profile}
                editable={editable}
                onSave={(f, m) => saveFacet("cultural", f as Record<string, unknown>, m)}
              />
            )}
            {active === "economic" && (
              <EconomicTab
                profile={profile}
                editable={editable}
                privateKey={wallet?.privateKey || null}
                onSave={(f, m) => saveFacet("economic", f as Record<string, unknown>, m)}
              />
            )}
          </div>
        </>
      )}

      {!profile && !loading && (
        <div className="rounded-xl border border-mempool-border bg-mempool-bg-elev p-6 text-center space-y-3">
          <div className="text-sm text-mempool-text-dim">
            No OmniBus ID has been created for this address yet.
          </div>
          {editable && (
            <button
              onClick={handleInit}
              disabled={initBusy}
              className="bg-mempool-blue hover:bg-mempool-blue/80 disabled:opacity-50 text-white text-sm font-semibold rounded-lg px-4 py-2"
            >
              {initBusy ? "Creating…" : "Create my OmniBus ID"}
            </button>
          )}
        </div>
      )}
    </div>
  );
}

// ── Header (DID + OBM cups) ────────────────────────────────────────────

function ProfileHeader({
  address,
  profile,
  editable,
  loading,
  onInit,
  initBusy,
}: {
  address: string;
  profile: ProfileFull | null;
  editable: boolean;
  loading: boolean;
  onInit: () => void;
  initBusy: boolean;
}) {
  const did = profile?.did || `did:omnibus:${address}`;
  const obm = profile?.obm;

  return (
    <div className="rounded-xl border border-mempool-border bg-mempool-bg-elev p-4 sm:p-5 space-y-3">
      <div className="flex items-start justify-between gap-3 flex-wrap">
        <div className="min-w-0 flex-1">
          <div className="text-[10px] text-mempool-text-dim uppercase tracking-wider">
            OmniBus ID
          </div>
          <div className="text-sm font-mono text-mempool-blue break-all">{did}</div>
          <div className="text-[11px] font-mono text-mempool-text-dim break-all mt-0.5">
            {address}
          </div>
        </div>
        {editable && !profile && !loading && (
          <button
            onClick={onInit}
            disabled={initBusy}
            className="bg-mempool-blue hover:bg-mempool-blue/80 disabled:opacity-50 text-white text-xs font-semibold rounded-lg px-3 py-1.5"
          >
            {initBusy ? "Creating…" : "Create"}
          </button>
        )}
      </div>

      {/* OBM cups (reputation) */}
      <div className="grid grid-cols-4 gap-2">
        <Cup emoji="💗" label="LOVE" value={obm?.love} color="from-pink-500/30 to-rose-600/30 border-pink-500/40 text-pink-300" />
        <Cup emoji="🍎" label="FOOD" value={obm?.food} color="from-red-500/30 to-orange-600/30 border-red-500/40 text-red-300" />
        <Cup emoji="🏠" label="RENT" value={obm?.rent} color="from-amber-500/30 to-yellow-600/30 border-amber-500/40 text-amber-300" />
        <Cup emoji="✈️" label="VACATION" value={obm?.vacation} color="from-sky-500/30 to-blue-600/30 border-sky-500/40 text-sky-300" />
      </div>

      {obm && (
        <div className="text-xs text-mempool-text-dim text-center">
          Reputation:{" "}
          <span className="text-mempool-text font-mono font-semibold">
            {obm.reputation.toLocaleString()}
          </span>
          {" / 1,000,000"}
        </div>
      )}
    </div>
  );
}

function Cup({
  emoji,
  label,
  value,
  color,
}: {
  emoji: string;
  label: string;
  value?: number;
  color: string;
}) {
  const pct = Math.max(0, Math.min(100, value ?? 0));
  return (
    <div className={`bg-gradient-to-br ${color} border rounded-lg p-2 text-center`}>
      <div className="text-lg leading-none">{emoji}</div>
      <div className="text-[9px] uppercase tracking-wider mt-1 opacity-80">{label}</div>
      <div className="text-sm font-mono font-bold mt-0.5">{pct}/100</div>
    </div>
  );
}

function TabBar({
  active,
  onSelect,
}: {
  active: TabKey;
  onSelect: (id: TabKey) => void;
}) {
  return (
    <>
      {/* Mobile: dropdown */}
      <div className="sm:hidden">
        <select
          value={active}
          onChange={(e) => onSelect(e.target.value as TabKey)}
          className="w-full bg-mempool-bg-elev border border-mempool-border rounded-lg px-3 py-2 text-sm text-mempool-text"
        >
          {TABS.map((t) => (
            <option key={t.id} value={t.id}>
              {t.emoji} {t.label}
            </option>
          ))}
        </select>
      </div>

      {/* Desktop: tab strip */}
      <nav className="hidden sm:flex gap-1 border-b border-mempool-border">
        {TABS.map((t) => (
          <button
            key={t.id}
            onClick={() => onSelect(t.id)}
            className={`px-4 py-2 text-sm font-medium transition-colors relative ${
              active === t.id
                ? "text-mempool-blue"
                : "text-mempool-text-dim hover:text-mempool-text"
            }`}
          >
            <span className="mr-1">{t.emoji}</span>
            {t.label}
            {active === t.id && (
              <div className="absolute bottom-0 left-0 right-0 h-0.5 bg-mempool-blue rounded-full" />
            )}
          </button>
        ))}
      </nav>
    </>
  );
}

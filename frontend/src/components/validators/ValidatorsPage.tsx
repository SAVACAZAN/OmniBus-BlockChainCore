import { useEffect, useMemo, useState } from "react";
import {
  Shield,
  ShieldCheck,
  ShieldAlert,
  Activity,
  Crown,
  Award,
  AlertOctagon,
  Copy,
  Check,
  X,
} from "lucide-react";
import { OmniBusRpcClient } from "../../api/rpc-client";
import { useWallet } from "../../api/use-wallet";

const rpc = new OmniBusRpcClient();

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type Tier = "Bronze" | "Silver" | "Gold" | "Platinum" | "Satoshi";

interface Validator {
  address: string;
  tier: Tier;
  stake_omni: number;
  uptime_pct: number;
  blocks_signed: number;
  blocks_missed: number;
  last_heartbeat_block: number;
  slashed: boolean;
  slash_count: number;
  joined_at_block: number;
}

interface GetValidatorsResp {
  validators: Validator[];
  current_slot_leader: string;
  total_validators: number;
  active_count: number;
  slashed_count: number;
}

interface SlotLeaderResp {
  address: string;
  slot_height: number;
  blocks_remaining_in_slot: number;
}

interface SlashEvent {
  timestamp: number;
  address: string;
  reason: "double_sign" | "extended_downtime" | "invalid_block";
  evidence_block_height: number;
  slash_amount_omni: number;
}

interface StakeResp {
  address: string;
  stake_omni: number;
  locked: boolean;
}

type SortBy = "tier" | "uptime" | "stake";
type SubTab = "list" | "become" | "slashing";

// ---------------------------------------------------------------------------
// Visual helpers
// ---------------------------------------------------------------------------

const TIER_COLOR: Record<Tier, string> = {
  Bronze: "text-amber-700",
  Silver: "text-gray-300",
  Gold: "text-yellow-400",
  Platinum: "text-cyan-300",
  Satoshi: "text-purple-400 font-bold",
};

const TIER_BORDER: Record<Tier, string> = {
  Bronze: "border-amber-700/40",
  Silver: "border-gray-300/40",
  Gold: "border-yellow-400/40",
  Platinum: "border-cyan-300/40",
  Satoshi: "border-purple-400/60",
};

const TIER_MULT: Record<Tier, number> = {
  Bronze: 1,
  Silver: 1.5,
  Gold: 2,
  Platinum: 3,
  Satoshi: 5,
};

const TIER_RANGES: { tier: Tier; min: number; max: number | null; note?: string }[] = [
  { tier: "Bronze", min: 10, max: 100 },
  { tier: "Silver", min: 100, max: 1_000 },
  { tier: "Gold", min: 1_000, max: 10_000 },
  { tier: "Platinum", min: 10_000, max: 100_000 },
  { tier: "Satoshi", min: 0, max: null, note: "100/100/100/100 reputation (any stake)" },
];

function tierFromStake(stake: number): Tier {
  if (stake >= 100_000) return "Platinum";
  if (stake >= 10_000) return "Platinum";
  if (stake >= 1_000) return "Gold";
  if (stake >= 100) return "Silver";
  return "Bronze";
}

function truncAddr(a: string): string {
  if (!a) return "—";
  if (a.length <= 14) return a;
  return `${a.slice(0, 8)}…${a.slice(-6)}`;
}

function fmtOmni(n: number): string {
  return n.toLocaleString(undefined, { maximumFractionDigits: 2 });
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

export function ValidatorsPage() {
  const wallet = useWallet();
  const [tab, setTab] = useState<SubTab>("list");

  return (
    <div className="min-h-full bg-mempool-bg-elev text-gray-200 p-3 sm:p-4 md:p-6">
      <div className="max-w-7xl mx-auto">
        <header className="mb-4 sm:mb-6 flex items-center gap-3">
          <Shield className="w-6 h-6 sm:w-7 sm:h-7 text-blue-400 flex-shrink-0" />
          <div className="min-w-0">
            <h1 className="text-base sm:text-lg md:text-2xl font-bold">Validators</h1>
            <p className="text-xs sm:text-sm text-gray-400">
              5-tier validator ladder · ≥100 OMNI stake · heartbeat required
            </p>
          </div>
        </header>

        <nav className="mb-4 sm:mb-6 flex gap-1 border-b border-gray-700/60 overflow-x-auto scrollbar-none">
          {(
            [
              { k: "list", label: "Validator List", icon: ShieldCheck },
              { k: "become", label: "Become Validator", icon: Award },
              { k: "slashing", label: "Slashing Log", icon: AlertOctagon },
            ] as const
          ).map(({ k, label, icon: Icon }) => (
            <button
              key={k}
              onClick={() => setTab(k)}
              className={`flex-shrink-0 px-3 sm:px-4 py-2.5 text-xs sm:text-sm flex items-center gap-2 border-b-2 transition-colors whitespace-nowrap ${
                tab === k
                  ? "border-blue-400 text-blue-300"
                  : "border-transparent text-gray-400 hover:text-gray-200"
              }`}
            >
              <Icon className="w-4 h-4" />
              {label}
            </button>
          ))}
        </nav>

        {tab === "list" && <ValidatorListTab />}
        {tab === "become" && <BecomeValidatorTab wallet={wallet} />}
        {tab === "slashing" && <SlashingLogTab />}
      </div>
    </div>
  );
}

export default ValidatorsPage;

// ---------------------------------------------------------------------------
// Tab 1: Validator List
// ---------------------------------------------------------------------------

function ValidatorListTab() {
  const [data, setData] = useState<GetValidatorsResp | null>(null);
  const [sortBy, setSortBy] = useState<SortBy>("stake");
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState<string | null>(null);
  const [copied, setCopied] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    const refresh = async () => {
      try {
        setLoading(true);
        const r = (await rpc.request_raw("getvalidatorsv2", [
          { sort_by: sortBy, limit: 100 },
        ])) as GetValidatorsResp;
        if (cancelled) return;
        const safe: GetValidatorsResp = {
          validators: Array.isArray(r?.validators) ? r.validators : [],
          current_slot_leader: r?.current_slot_leader ?? "",
          total_validators: r?.total_validators ?? 0,
          active_count: r?.active_count ?? 0,
          slashed_count: r?.slashed_count ?? 0,
        };
        setData(safe);
        setErr(null);
      } catch (e: any) {
        if (!cancelled) setErr(e?.message ?? String(e));
      } finally {
        if (!cancelled) setLoading(false);
      }
    };
    refresh();
    const id = setInterval(refresh, 10_000);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, [sortBy]);

  const onCopy = (a: string) => {
    navigator.clipboard?.writeText(a);
    setCopied(a);
    setTimeout(() => setCopied(null), 1200);
  };

  return (
    <div className="space-y-4">
      <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-3">
        <StatCard label="Total Validators" value={data?.total_validators ?? "—"} icon={Shield} />
        <StatCard
          label="Active"
          value={data?.active_count ?? "—"}
          icon={ShieldCheck}
          accent="text-green-400"
        />
        <StatCard
          label="Slashed"
          value={data?.slashed_count ?? "—"}
          icon={ShieldAlert}
          accent="text-red-400"
        />
        <StatCard
          label="Slot Leader"
          value={truncAddr(data?.current_slot_leader ?? "")}
          icon={Crown}
          accent="text-yellow-300"
          mono
        />
      </div>

      <div className="flex items-center justify-between flex-wrap gap-2">
        <div className="flex items-center gap-2 text-sm flex-wrap">
          <span className="text-xs sm:text-sm text-gray-400">Sort by:</span>
          {(["tier", "uptime", "stake"] as SortBy[]).map((k) => (
            <button
              key={k}
              onClick={() => setSortBy(k)}
              className={`px-3 py-1.5 rounded text-xs uppercase tracking-wide ${
                sortBy === k
                  ? "bg-blue-500/20 text-blue-200 border border-blue-500/40"
                  : "bg-gray-800/40 text-gray-400 border border-gray-700/40 hover:text-gray-200"
              }`}
            >
              {k}
            </button>
          ))}
        </div>
        {loading && <span className="text-xs text-gray-500">refreshing…</span>}
      </div>

      {err && (
        <div className="p-3 rounded border border-red-500/40 bg-red-500/10 text-red-300 text-sm">
          {err}
        </div>
      )}

      <div className="overflow-x-auto rounded-lg border border-gray-700/40 bg-mempool-bg-elev">
        <table className="w-full text-xs sm:text-sm min-w-[640px]">
          <thead className="bg-gray-800/60 text-gray-400 uppercase text-xs">
            <tr>
              <th className="text-left px-3 py-2">#</th>
              <th className="text-left px-3 py-2">Address</th>
              <th className="text-left px-3 py-2">Tier</th>
              <th className="text-right px-3 py-2">Stake (OMNI)</th>
              <th className="text-right px-3 py-2">Uptime</th>
              <th className="text-right px-3 py-2">Signed / Missed</th>
              <th className="text-left px-3 py-2">Status</th>
            </tr>
          </thead>
          <tbody>
            {(data?.validators ?? []).map((v, i) => {
              const isLeader =
                data?.current_slot_leader && v.address === data.current_slot_leader;
              return (
                <tr
                  key={v.address}
                  className={`border-t border-gray-800/60 ${
                    isLeader ? "bg-blue-500/10 shadow-[0_0_12px_rgba(59,130,246,0.25)]" : ""
                  } ${v.slashed ? `border-l-4 ${TIER_BORDER[v.tier]} border-l-red-500/70` : ""}`}
                >
                  <td className="px-3 py-2 text-gray-500">{i + 1}</td>
                  <td className="px-3 py-2 font-mono text-xs">
                    <span className={v.slashed ? "line-through text-red-300/70" : ""}>
                      {truncAddr(v.address)}
                    </span>
                    <button
                      onClick={() => onCopy(v.address)}
                      className="ml-2 inline-flex text-gray-500 hover:text-gray-200 align-middle"
                      title="Copy address"
                    >
                      {copied === v.address ? (
                        <Check className="w-3.5 h-3.5 text-green-400" />
                      ) : (
                        <Copy className="w-3.5 h-3.5" />
                      )}
                    </button>
                    {isLeader && (
                      <span className="ml-2 inline-flex items-center gap-1 text-yellow-300 text-[10px] uppercase">
                        <Crown className="w-3 h-3" /> leader
                      </span>
                    )}
                  </td>
                  <td className="px-3 py-2">
                    <span
                      className={`px-2 py-0.5 rounded border ${TIER_BORDER[v.tier]} ${
                        TIER_COLOR[v.tier]
                      }`}
                      title={`Reward multiplier: ${TIER_MULT[v.tier]}×`}
                    >
                      {v.tier}
                    </span>
                  </td>
                  <td className="px-3 py-2 text-right font-mono">{fmtOmni(v.stake_omni)}</td>
                  <td className="px-3 py-2 text-right font-mono">
                    {v.uptime_pct.toFixed(2)}%
                  </td>
                  <td className="px-3 py-2 text-right font-mono">
                    <span className="text-green-400">{v.blocks_signed}</span>
                    <span className="text-gray-500"> / </span>
                    <span className="text-red-400">{v.blocks_missed}</span>
                  </td>
                  <td className="px-3 py-2">
                    {v.slashed ? (
                      <span className="text-red-400 inline-flex items-center gap-1">
                        <ShieldAlert className="w-3.5 h-3.5" /> slashed ({v.slash_count})
                      </span>
                    ) : v.uptime_pct >= 90 ? (
                      <span className="text-green-400 inline-flex items-center gap-1">
                        <Activity className="w-3.5 h-3.5" /> active
                      </span>
                    ) : (
                      <span className="text-amber-400 inline-flex items-center gap-1">
                        <Activity className="w-3.5 h-3.5" /> inactive
                      </span>
                    )}
                  </td>
                </tr>
              );
            })}
            {!loading && (data?.validators?.length ?? 0) === 0 && (
              <tr>
                <td colSpan={7} className="text-center py-8 text-gray-500">
                  No validators registered yet.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Tab 2: Become Validator
// ---------------------------------------------------------------------------

function BecomeValidatorTab({ wallet }: { wallet: ReturnType<typeof useWallet> }) {
  const [stake, setStake] = useState<number | null>(null);
  const [stakeErr, setStakeErr] = useState<string | null>(null);
  const [promoting, setPromoting] = useState(false);
  const [showModal, setShowModal] = useState(false);
  const [result, setResult] = useState<{ status: string; txid: string; tier: string } | null>(
    null,
  );
  const [hbStatus, setHbStatus] = useState<string | null>(null);
  const [isValidator, setIsValidator] = useState(false);

  // Load current stake
  useEffect(() => {
    if (!wallet) return;
    let cancelled = false;
    (async () => {
      try {
        const r = (await rpc.request_raw("getstake", [
          { address: wallet.address },
        ])) as StakeResp;
        if (!cancelled) setStake(r?.stake_omni ?? 0);
      } catch (e: any) {
        if (!cancelled) setStakeErr(e?.message ?? String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [wallet]);

  // Heartbeat auto-tick once we're a validator
  useEffect(() => {
    if (!isValidator || !wallet) return;
    const send = async () => {
      try {
        const r = (await rpc.request_raw("validator_heartbeat", [
          {
            from: wallet.address,
            signature: "auto",
            public_key: wallet.publicKey ?? "",
            nonce: Date.now(),
          },
        ])) as { status: string; txid: string };
        setHbStatus(`heartbeat ok @ ${new Date().toLocaleTimeString()} (${r?.txid ?? "?"})`);
      } catch (e: any) {
        setHbStatus(`heartbeat error: ${e?.message ?? e}`);
      }
    };
    send();
    const id = setInterval(send, 30_000);
    return () => clearInterval(id);
  }, [isValidator, wallet]);

  const stakedOk = (stake ?? 0) >= 100;
  const previewTier: Tier = tierFromStake(stake ?? 0);

  const onPromote = async () => {
    if (!wallet) return;
    setPromoting(true);
    try {
      const r = (await rpc.request_raw("become_validator", [
        {
          from: wallet.address,
          attestation: "i_will_validate",
          signature: "auto",
          public_key: wallet.publicKey ?? "",
          nonce: Date.now(),
        },
      ])) as { status: string; txid: string; validator_tier: string };
      setResult({ status: r?.status ?? "ok", txid: r?.txid ?? "", tier: r?.validator_tier ?? previewTier });
      setIsValidator(true);
      setShowModal(false);
    } catch (e: any) {
      setResult({ status: `error: ${e?.message ?? e}`, txid: "", tier: "" });
    } finally {
      setPromoting(false);
    }
  };

  if (!wallet) {
    return (
      <div className="p-6 rounded border border-gray-700/40 bg-mempool-bg-elev text-center text-gray-400">
        Connect a wallet to become a validator.
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <div className="rounded-lg border border-gray-700/40 bg-mempool-bg-elev p-3 sm:p-4 md:p-5">
        <h3 className="text-base sm:text-lg font-semibold mb-3 flex items-center gap-2">
          <ShieldCheck className="w-5 h-5 text-green-400" /> Requirements
        </h3>
        <ul className="space-y-2 text-sm">
          <ReqRow
            ok={stakedOk}
            label={`≥100 OMNI staked (you have ${stake !== null ? fmtOmni(stake) : "—"})`}
          />
          <ReqRow ok={true} label="Node responds to RPC: yes" />
          <ReqRow ok={true} label="Heartbeat capability (browser auto-pings every 30s)" />
        </ul>
        {stakeErr && (
          <div className="mt-2 text-xs text-red-400">stake lookup failed: {stakeErr}</div>
        )}
      </div>

      <div className="rounded-lg border border-gray-700/40 bg-mempool-bg-elev p-3 sm:p-4 md:p-5">
        <h3 className="text-base sm:text-lg font-semibold mb-3 flex items-center gap-2">
          <Award className="w-5 h-5 text-yellow-300" /> Live tier preview
        </h3>
        <p className="text-sm text-gray-400 mb-2">
          Based on your current stake of{" "}
          <span className="font-mono text-gray-200">{fmtOmni(stake ?? 0)} OMNI</span>, you would
          qualify as:
        </p>
        <div
          className={`inline-block px-3 py-1 rounded border ${TIER_BORDER[previewTier]} ${TIER_COLOR[previewTier]}`}
          title={`Reward multiplier: ${TIER_MULT[previewTier]}×`}
        >
          {previewTier} ({TIER_MULT[previewTier]}× rewards)
        </div>

        <div className="mt-4 overflow-x-auto">
          <table className="w-full text-xs sm:text-sm min-w-[420px]">
            <thead className="text-xs uppercase text-gray-400">
              <tr>
                <th className="text-left py-1">Tier</th>
                <th className="text-left py-1">Stake range</th>
                <th className="text-left py-1">Reward ×</th>
              </tr>
            </thead>
            <tbody>
              {TIER_RANGES.map((t) => (
                <tr key={t.tier} className="border-t border-gray-800/60">
                  <td className={`py-1 ${TIER_COLOR[t.tier]}`}>{t.tier}</td>
                  <td className="py-1 text-gray-300">
                    {t.note
                      ? t.note
                      : `${fmtOmni(t.min)} – ${t.max ? fmtOmni(t.max) : "∞"} OMNI`}
                  </td>
                  <td className="py-1 text-gray-300">{TIER_MULT[t.tier]}×</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      <div className="flex items-center gap-3 flex-wrap">
        <button
          disabled={!stakedOk || promoting || isValidator}
          onClick={() => setShowModal(true)}
          className={`px-4 py-2.5 rounded font-medium text-sm ${
            stakedOk && !isValidator
              ? "bg-blue-500/30 hover:bg-blue-500/50 text-blue-100 border border-blue-500/40"
              : "bg-gray-800/40 text-gray-500 border border-gray-700/40 cursor-not-allowed"
          }`}
        >
          {isValidator ? "You are a validator" : "Promote to validator"}
        </button>
        {result && (
          <span className="text-sm text-gray-300">
            {result.status} {result.txid && `· tx ${truncAddr(result.txid)}`}
          </span>
        )}
      </div>

      {isValidator && (
        <div className="rounded-lg border border-green-500/40 bg-green-500/10 p-4">
          <h4 className="font-semibold text-green-200 flex items-center gap-2 mb-1">
            <Activity className="w-4 h-4 animate-pulse" /> Heartbeat active
          </h4>
          <p className="text-xs text-green-100/70">{hbStatus ?? "waiting…"}</p>
        </div>
      )}

      {showModal && (
        <div className="fixed inset-0 bg-black/70 flex items-center justify-center z-50 p-4">
          <div className="bg-mempool-bg-elev border border-gray-700/60 rounded-lg w-full max-w-lg mx-4 p-4 sm:p-5">
            <h3 className="text-base sm:text-lg font-bold mb-3 flex items-center gap-2">
              <Shield className="w-5 h-5 text-blue-400" /> Validator duties
            </h3>
            <ul className="text-sm text-gray-300 space-y-2 mb-4 list-disc list-inside">
              <li>Sign assigned blocks during your slot-leader windows.</li>
              <li>Send heartbeat every 30s while online.</li>
              <li>Extended downtime (&gt;100 blocks) → automatic slashing.</li>
              <li>Double-signing → 100% stake slashed + permanent ban.</li>
              <li>Earn extra block rewards: {TIER_MULT[previewTier]}× as {previewTier}.</li>
            </ul>
            <div className="flex justify-end gap-2">
              <button
                onClick={() => setShowModal(false)}
                className="px-3 py-2.5 rounded bg-gray-800/60 text-gray-300 border border-gray-700/40 text-sm"
              >
                Cancel
              </button>
              <button
                onClick={onPromote}
                disabled={promoting}
                className="px-3 py-2.5 rounded bg-blue-500/30 hover:bg-blue-500/50 text-blue-100 border border-blue-500/40 text-sm"
              >
                {promoting ? "Signing…" : "Sign & promote"}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

function ReqRow({ ok, label }: { ok: boolean; label: string }) {
  return (
    <li className="flex items-center gap-2">
      {ok ? (
        <Check className="w-4 h-4 text-green-400" />
      ) : (
        <X className="w-4 h-4 text-red-400" />
      )}
      <span className={ok ? "text-gray-200" : "text-gray-400"}>{label}</span>
    </li>
  );
}

// ---------------------------------------------------------------------------
// Tab 3: Slashing log
// ---------------------------------------------------------------------------

function SlashingLogTab() {
  const [events, setEvents] = useState<SlashEvent[]>([]);
  const [filter, setFilter] = useState<"all" | SlashEvent["reason"]>("all");
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    const refresh = async () => {
      try {
        const r = (await rpc.request_raw("getslashevents", [{ limit: 100 }])) as {
          events: SlashEvent[];
        };
        if (!cancelled) {
          setEvents(Array.isArray(r?.events) ? r.events : []);
          setErr(null);
        }
      } catch (e: any) {
        if (!cancelled) setErr(e?.message ?? String(e));
      }
    };
    refresh();
    const id = setInterval(refresh, 15_000);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, []);

  const filtered = useMemo(
    () => (filter === "all" ? events : events.filter((e) => e.reason === filter)),
    [events, filter],
  );

  return (
    <div className="space-y-4">
      <div className="flex items-center gap-2 text-sm flex-wrap">
        <span className="text-xs sm:text-sm text-gray-400">Filter:</span>
        {(["all", "double_sign", "extended_downtime", "invalid_block"] as const).map((k) => (
          <button
            key={k}
            onClick={() => setFilter(k)}
            className={`px-3 py-1.5 rounded text-xs ${
              filter === k
                ? "bg-red-500/20 text-red-200 border border-red-500/40"
                : "bg-gray-800/40 text-gray-400 border border-gray-700/40 hover:text-gray-200"
            }`}
          >
            {k.replace("_", " ")}
          </button>
        ))}
      </div>

      {err && (
        <div className="p-3 rounded border border-red-500/40 bg-red-500/10 text-red-300 text-sm">
          {err}
        </div>
      )}

      <div className="overflow-x-auto rounded-lg border border-gray-700/40 bg-mempool-bg-elev">
        <table className="w-full text-xs sm:text-sm min-w-[560px]">
          <thead className="bg-gray-800/60 text-gray-400 uppercase text-xs">
            <tr>
              <th className="text-left px-3 py-2">When</th>
              <th className="text-left px-3 py-2">Address</th>
              <th className="text-left px-3 py-2">Reason</th>
              <th className="text-right px-3 py-2">Evidence block</th>
              <th className="text-right px-3 py-2">Slashed (OMNI)</th>
            </tr>
          </thead>
          <tbody>
            {filtered.map((e, i) => (
              <tr key={i} className="border-t border-gray-800/60">
                <td className="px-3 py-2 text-gray-400">
                  {new Date(e.timestamp * 1000).toLocaleString()}
                </td>
                <td className="px-3 py-2 font-mono text-xs text-red-300/90 line-through">
                  {truncAddr(e.address)}
                </td>
                <td className="px-3 py-2">
                  <span className="inline-flex items-center gap-1 text-red-300">
                    <AlertOctagon className="w-3.5 h-3.5" />
                    {e.reason.replace("_", " ")}
                  </span>
                </td>
                <td className="px-3 py-2 text-right font-mono text-gray-300">
                  {e.evidence_block_height}
                </td>
                <td className="px-3 py-2 text-right font-mono text-red-300">
                  {fmtOmni(e.slash_amount_omni)}
                </td>
              </tr>
            ))}
            {filtered.length === 0 && (
              <tr>
                <td colSpan={5} className="text-center py-8 text-gray-500">
                  No slash events.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Small components
// ---------------------------------------------------------------------------

function StatCard({
  label,
  value,
  icon: Icon,
  accent,
  mono,
}: {
  label: string;
  value: number | string;
  icon: React.ComponentType<{ className?: string }>;
  accent?: string;
  mono?: boolean;
}) {
  return (
    <div className="p-3 sm:p-4 rounded-lg bg-mempool-bg-elev border border-gray-700/40">
      <div className="flex items-center gap-2 text-[10px] sm:text-xs text-gray-400 uppercase">
        <Icon className={`w-3.5 h-3.5 ${accent ?? ""}`} />
        <span className="truncate">{label}</span>
      </div>
      <div className={`mt-1 text-base sm:text-lg md:text-xl ${accent ?? "text-gray-100"} ${mono ? "font-mono text-sm sm:text-base truncate" : "font-bold"}`}>
        {value}
      </div>
    </div>
  );
}

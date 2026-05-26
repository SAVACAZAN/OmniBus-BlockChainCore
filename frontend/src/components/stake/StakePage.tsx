/**
 * StakePage.tsx — Stake new + manage stakes + leaderboard.
 *
 * Stake on OmniBus locks OMNI for a chosen duration → earns RENT reputation
 * (one of the 4 soulbound domains: LOVE/FOOD/RENT/VACATION). Reputation is
 * stored ×100 on chain (1050 = 10.50 RENT). Amounts are in SAT (1e9 / OMNI).
 *
 * Backend RPCs (rpc_server.zig handlers in flight):
 *   - stake       { from, amount_sat, lock_blocks, signature, public_key, nonce }
 *   - unstake     { from, stake_id, signature, public_key, nonce }
 *   - getstakers  { sort_by?, limit? }
 *   - getstake    { address }
 *   - getblockcount
 *
 * Signing uses the existing ECDSA path from `wallet-keystore` + a canonical
 * "STAKE_V1" / "UNSTAKE_V1" message — keep these strings in sync with the
 * verifier in rpc_server.zig.
 */

import { useCallback, useEffect, useMemo, useState } from "react";
import {
  Coins,
  Lock,
  TrendingUp,
  Clock,
  AlertTriangle,
  RefreshCw,
} from "lucide-react";
import { rpc } from "../../api/rpc-client";
import { SAT_PER_OMNI, midTrunc, fmtOmni, fmtInt } from "../../utils/fmt";
import { AddressLabel } from "../common/AddressLabel";
import { useWallet } from "../../api/use-wallet";
import { signMessage } from "../../api/exchange-sign";
import { useGlobalBalance, refreshGlobalBalance } from "../../api/use-global-balance";
import { useBlockHeight } from "../../api/use-block-height";


// ── Constants ─────────────────────────────────────────────────────────────


const BLOCK_TIME_S = 1; // chain block time used for day math (1s/block)
const BLOCKS_PER_DAY = 86_400 / BLOCK_TIME_S;
const UNBONDING_BLOCKS = 7 * BLOCKS_PER_DAY; // 7-day cooling-off after unstake

const LOCK_PRESETS = [
  { days: 7,   label: "7 days",   multiplierHint: "1.0×" },
  { days: 30,  label: "30 days",  multiplierHint: "1.2×" },
  { days: 90,  label: "90 days",  multiplierHint: "1.5×" },
  { days: 365, label: "365 days", multiplierHint: "2.0×" },
] as const;

const BASE_RENT_PER_OMNI_PER_DAY = 0.10; // baseline RENT/day before tier mult.

// ── Types (no `any` for RPC results) ──────────────────────────────────────

type StakeStatus = "active" | "unbonding" | "completed";

const STAKE_STATUS_BADGE: Record<StakeStatus, string> = {
  active:    "bg-mempool-green/15 text-mempool-green border-mempool-green/40",
  unbonding: "bg-mempool-orange/15 text-mempool-orange border-mempool-orange/40",
  completed: "bg-mempool-border/30 text-mempool-text-dim border-mempool-border",
};

interface StakeEntry {
  id: number;
  amount_sat: number;
  lock_blocks: number;
  started_at_block: number;
  days_locked: number;
  rent_earned: number;       // ×100 on chain
  status: StakeStatus;
  unbonding_until?: number;  // block height
}

interface StakerRow {
  address: string;
  amount_sat: number;
  lock_blocks: number;
  started_at_block: number;
  days_locked: number;
  rent_earned: number;       // ×100 on chain
}

interface GetStakeResp { stakes: StakeEntry[] }
interface GetStakersResp { stakers: StakerRow[] }
interface StakeResp { status: string; txid: string; stake_id: number }
interface UnstakeResp { status: string; txid: string; unbonding_until_block: number }

type SubTab = "mine" | "new" | "top" | "activity";

const STAKE_TABS: { id: SubTab; label: string }[] = [
  { id: "mine",     label: "My Stakes" },
  { id: "new",      label: "Stake new" },
  { id: "top",      label: "Top Stakers" },
  { id: "activity", label: "Activity" },
];

// ── Activity tab — stake / unstake history pulled from getaddresshistory ──

interface AddressHistoryTx {
  txid: string;
  from: string;
  to: string;
  amount: number;
  fee: number;
  confirmations: number;
  blockHeight: number | null;
  direction: "sent" | "received";
  kind?: string;
  status: "pending" | "confirmed";
}

interface AddressHistoryResp {
  address: string;
  transactions: AddressHistoryTx[];
  count: number;
  totalReceived: number;
  totalSent: number;
}
type SortBy = "amount" | "rent" | "days";

// ── Format helpers ────────────────────────────────────────────────────────

const repFmt = new Intl.NumberFormat("en-US", {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});

function fmtRent(rentX100: number): string {
  return repFmt.format(rentX100 / 100);
}
function tierMultiplier(amountOmni: number): number {
  if (amountOmni >= 10_000) return 3.0;
  if (amountOmni >= 1_000)  return 2.0;
  if (amountOmni >= 100)    return 1.5;
  return 1.0;
}

// ── Signing (canonical messages — must match rpc_server.zig) ──────────────

function signStakePayload(args: {
  privateKeyHex: string; from: string; amountSat: number; lockBlocks: number; nonce: number;
}): { signature: string; publicKey: string } {
  const msg = `STAKE_V1\n${args.from}\n${args.amountSat}\n${args.lockBlocks}\n${args.nonce}`;
  return signMessage(args.privateKeyHex, msg);
}
function signUnstakePayload(args: {
  privateKeyHex: string; from: string; stakeId: number; nonce: number;
}): { signature: string; publicKey: string } {
  const msg = `UNSTAKE_V1\n${args.from}\n${args.stakeId}\n${args.nonce}`;
  return signMessage(args.privateKeyHex, msg);
}

// ── Component ─────────────────────────────────────────────────────────────

export function StakePage() {
  const [tab, setTab] = useState<SubTab>("mine");
  const blockHeight = useBlockHeight();

  return (
    <section className="bg-mempool-bg-elev rounded-lg p-3 sm:p-4 border border-mempool-border backdrop-blur-sm">
      <div className="flex items-center gap-2 sm:gap-3 mb-4">
        <Coins className="w-5 h-5 text-mempool-blue flex-shrink-0" />
        <h2 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
          Stake
        </h2>
        <div className="flex-1 h-px bg-mempool-border" />
        <span className="text-[10px] sm:text-xs text-mempool-text-dim font-mono whitespace-nowrap">
          height {fmtInt(blockHeight)}
        </span>
      </div>

      {/* Sub-tab bar (matches App.tsx tab styling) */}
      <div className="flex gap-1 border-b border-mempool-border mb-4 overflow-x-auto scrollbar-none">
        {STAKE_TABS.map((t) => {
          const active = tab === t.id;
          return (
            <button
              key={t.id}
              onClick={() => setTab(t.id)}
              className={
                "relative flex-shrink-0 px-3 sm:px-4 py-2.5 text-xs font-medium uppercase tracking-wider transition-colors whitespace-nowrap " +
                (active
                  ? "text-mempool-blue"
                  : "text-mempool-text-dim hover:text-mempool-text")
              }
            >
              {t.label}
              {active && (
                <span className="absolute left-0 right-0 -bottom-px h-0.5 bg-mempool-blue" />
              )}
            </button>
          );
        })}
      </div>

      {tab === "mine"     && <MyStakesTab blockHeight={blockHeight} />}
      {tab === "new"      && <StakeNewTab blockHeight={blockHeight} />}
      {tab === "top"      && <TopStakersTab />}
      {tab === "activity" && <StakeActivityTab />}
    </section>
  );
}

// ── Tab 1: My Stakes ──────────────────────────────────────────────────────

function MyStakesTab({ blockHeight }: { blockHeight: number }) {
  // Live wallet from the global keystore (subscribes to lock/unlock from any
  // tab via subscribeWallet). When connected, the wallet address always wins
  // over any locally typed lookup address — switching tabs after connecting
  // in the Header instantly shows the user's stakes.
  const wallet = useWallet();
  const [addrInput, setAddrInput] = useState<string>("");
  const effectiveAddress = wallet?.address ?? addrInput.trim();

  const [stakes, setStakes] = useState<StakeEntry[] | null>(null);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [unstakeBusy, setUnstakeBusy] = useState<number | null>(null);
  const [unstakeModalId, setUnstakeModalId] = useState<number | null>(null);
  const [toast, setToast] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    if (!effectiveAddress) { setStakes([]); return; }
    setLoading(true);
    setErr(null);
    try {
      const r = (await rpc.getStake(effectiveAddress)) as GetStakeResp | null;
      setStakes(r?.stakes ?? []);
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
      setStakes([]);
    } finally {
      setLoading(false);
    }
  }, [effectiveAddress]);

  useEffect(() => { void refresh(); }, [refresh]);

  const totals = useMemo(() => {
    const list = stakes ?? [];
    let totalSat = 0;
    let totalRent = 0;
    for (const s of list) {
      if (s.status !== "completed") totalSat += s.amount_sat;
      totalRent += s.rent_earned;
    }
    return { totalSat, totalRent };
  }, [stakes]);

  const doUnstake = async (stakeId: number) => {
    if (!wallet) { setToast("Connect wallet to unstake"); return; }
    setUnstakeBusy(stakeId);
    try {
      // Fetch sequential nonce from chain (see doStake for why).
      const nonce = await rpc.getNonce(wallet.address).catch(() => 0);
      const { signature, publicKey } = signUnstakePayload({
        privateKeyHex: wallet.privateKey,
        from: wallet.address,
        stakeId,
        nonce,
      });
      const r = (await rpc.request_raw("unstake", [{
        from: wallet.address,
        stake_id: stakeId,
        signature,
        public_key: publicKey,
        nonce,
      }])) as UnstakeResp;
      setToast(`Unstake submitted — txid ${r.txid.slice(0, 12)}…`);
      setUnstakeModalId(null);
      await refresh();
    } catch (e) {
      setToast(`Unstake failed: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setUnstakeBusy(null);
      window.setTimeout(() => setToast(null), 6000);
    }
  };

  return (
    <div className="space-y-4">
      {/* Address row */}
      <div className="flex flex-wrap items-center gap-2">
        {wallet ? (
          <span className="text-xs text-mempool-text-dim font-mono truncate max-w-full">
            wallet: <span className="text-mempool-text break-all">{wallet.address}</span>
          </span>
        ) : (
          <input
            type="text"
            value={addrInput}
            onChange={(e) => setAddrInput(e.target.value)}
            placeholder="ob1q… (paste address to view stakes)"
            className="flex-1 min-w-0 sm:min-w-[280px] w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
          />
        )}
        <button
          onClick={() => void refresh()}
          disabled={loading}
          className="flex items-center gap-1.5 px-3 py-2 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue disabled:opacity-50"
        >
          <RefreshCw className={`w-3.5 h-3.5 ${loading ? "animate-spin" : ""}`} />
          Refresh
        </button>
      </div>

      {/* Summary */}
      <div className="grid grid-cols-2 gap-3">
        <div className="bg-mempool-bg border border-mempool-border rounded p-3">
          <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim">Total staked (active)</div>
          <div className="text-lg font-mono text-mempool-text mt-1">
            {fmtOmni(totals.totalSat)} <span className="text-xs text-mempool-text-dim">OMNI</span>
          </div>
        </div>
        <div className="bg-mempool-bg border border-mempool-border rounded p-3">
          <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim">Total RENT earned</div>
          <div className="text-lg font-mono text-mempool-green mt-1">
            {fmtRent(totals.totalRent)} <span className="text-xs text-mempool-text-dim">RENT</span>
          </div>
        </div>
      </div>

      {/* List */}
      {err && (
        <p className="text-xs text-mempool-orange font-mono">{err}</p>
      )}
      {!err && stakes && stakes.length === 0 && (
        <p className="text-xs text-mempool-text-dim font-mono py-6 text-center">
          No stakes yet. Open the “Stake new” tab to lock OMNI and start earning RENT.
        </p>
      )}
      {stakes && stakes.length > 0 && (
        <div className="space-y-2">
          {stakes.map((s) => (
            <StakeCard
              key={s.id}
              stake={s}
              blockHeight={blockHeight}
              onUnstake={() => setUnstakeModalId(s.id)}
              busy={unstakeBusy === s.id}
            />
          ))}
        </div>
      )}

      {/* Unstake modal */}
      {unstakeModalId !== null && (
        <div className="fixed inset-0 bg-black/60 flex items-center justify-center z-50 p-4">
          <div className="bg-mempool-bg-elev border border-mempool-border rounded-lg w-full max-w-md mx-4 p-4 sm:p-5 space-y-4">
            <div className="flex items-center gap-2">
              <AlertTriangle className="w-5 h-5 text-mempool-orange" />
              <h3 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
                Confirm unstake
              </h3>
            </div>
            <p className="text-xs text-mempool-text-dim leading-relaxed">
              Unstaking starts a <span className="text-mempool-orange font-mono">7-day unbonding</span>
              {" "}period ({fmtInt(UNBONDING_BLOCKS)} blocks). During unbonding the funds
              are locked but accrue no further RENT. Funds become spendable after unbonding ends.
            </p>
            <div className="flex justify-end gap-2 pt-2">
              <button
                onClick={() => setUnstakeModalId(null)}
                className="px-3 py-2.5 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-text"
              >
                Cancel
              </button>
              <button
                onClick={() => void doUnstake(unstakeModalId)}
                disabled={unstakeBusy !== null}
                className="px-3 py-2.5 text-xs rounded bg-mempool-orange/20 text-mempool-orange border border-mempool-orange/40 hover:bg-mempool-orange/30 disabled:opacity-50"
              >
                {unstakeBusy !== null ? "Submitting…" : "Confirm unstake"}
              </button>
            </div>
          </div>
        </div>
      )}

      {toast && (
        <div className="fixed bottom-4 right-4 bg-mempool-bg-elev border border-mempool-border rounded px-4 py-2 text-xs text-mempool-text font-mono shadow-lg z-50">
          {toast}
        </div>
      )}
    </div>
  );
}

function StakeCard({
  stake, blockHeight, onUnstake, busy,
}: {
  stake: StakeEntry; blockHeight: number; onUnstake: () => void; busy: boolean;
}) {
  const blocksRemaining = Math.max(
    0,
    stake.started_at_block + stake.lock_blocks - blockHeight,
  );
  const daysRemaining = Math.ceil(blocksRemaining / BLOCKS_PER_DAY);

  const statusBadge = STAKE_STATUS_BADGE[stake.status] ?? STAKE_STATUS_BADGE.completed;

  return (
    <div className="bg-mempool-bg border border-mempool-border rounded p-3">
      <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
        <div className="flex items-center gap-2">
          <Lock className="w-4 h-4 text-mempool-blue" />
          <span className="text-[10px] uppercase tracking-wider text-mempool-text-dim">#{stake.id}</span>
        </div>
        <div className="font-mono">
          <span className="text-base text-mempool-text">{fmtOmni(stake.amount_sat)}</span>
          <span className="text-xs text-mempool-text-dim ml-1">OMNI</span>
        </div>
        <div className="text-xs text-mempool-text-dim font-mono">
          lock {fmtInt(stake.lock_blocks)} blk · {stake.days_locked}d
        </div>
        <div className="text-xs font-mono">
          <span className="text-mempool-text-dim">RENT</span>{" "}
          <span className="text-mempool-green">{fmtRent(stake.rent_earned)}</span>
        </div>
        <span className={`text-[10px] uppercase tracking-wider px-2 py-0.5 rounded border font-medium ${statusBadge}`}>
          {stake.status}
        </span>
        <div className="flex-1" />
        {stake.status === "active" && (
          <button
            onClick={onUnstake}
            disabled={busy}
            className="px-3 py-1 text-xs rounded border border-mempool-orange/40 text-mempool-orange hover:bg-mempool-orange/10 disabled:opacity-50"
          >
            Unstake
          </button>
        )}
      </div>
      <div className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-[11px] text-mempool-text-dim font-mono">
        <span>started @ block {fmtInt(stake.started_at_block)}</span>
        {stake.status === "active" && (
          <span>unlocks in ~{daysRemaining}d ({fmtInt(blocksRemaining)} blk)</span>
        )}
        {stake.status === "unbonding" && stake.unbonding_until !== undefined && (
          <span className="text-mempool-orange">
            unbonding until block {fmtInt(stake.unbonding_until)}
          </span>
        )}
      </div>
    </div>
  );
}

// ── Tab 2: Stake new ──────────────────────────────────────────────────────

function StakeNewTab({ blockHeight }: { blockHeight: number }) {
  const wallet = useWallet();
  const [amountStr, setAmountStr] = useState<string>("");
  const [days, setDays] = useState<number>(30);
  const [busy, setBusy] = useState(false);
  const [toast, setToast] = useState<string | null>(null);

  // Use the global atomic snapshot so this tab agrees with Wallet / Exchange /
  // Header pill. Previously we did dual-fetch (getbalance + getstake) and
  // computed available manually — that worked but ignored in_orders, so
  // open sell orders ate into "available" without showing it. Now the same
  // singleton sources every page.
  const globalBal = useGlobalBalance();
  const refreshBalance = useCallback(async () => {
    refreshGlobalBalance();
  }, []);

  const amountOmni = parseFloat(amountStr) || 0;
  const amountSat = Math.floor(amountOmni * SAT_PER_OMNI);
  const lockBlocks = days * BLOCKS_PER_DAY;
  const tier = tierMultiplier(amountOmni);
  const durationMult = days >= 365 ? 2.0 : days >= 90 ? 1.5 : days >= 30 ? 1.2 : 1.0;
  const estRentPerDay = BASE_RENT_PER_OMNI_PER_DAY * amountOmni * tier * durationMult;
  const estRentTotal = estRentPerDay * days;

  // Same address-gated view as the rest of the UI: the snapshot only applies
  // to the connected wallet. Cast to null when wallet not yet propagated so
  // the existing null checks below keep working.
  const isLive = !!wallet && globalBal.address === wallet.address && globalBal.fetched_at > 0;
  const balanceSat = isLive ? globalBal.wallet_sat : null;
  const stakedSat = isLive ? globalBal.staked_sat : 0;
  const availableSat = isLive ? globalBal.available_sat : null;

  const canSubmit = !!wallet && amountSat > 0 && !busy
    && (availableSat === null || amountSat <= availableSat);

  const doStake = async () => {
    if (!wallet) { setToast("Connect wallet first"); return; }
    setBusy(true);
    try {
      // CRITICAL: chain expects sequential nonce (chain_nonce + pending),
      // NOT Date.now() — TXs with non-sequential nonce are rejected silently
      // by validateTransaction (`nonce {d} != expected {d}`). Fetch from
      // chain via `getnonce` so each stake submission gets the real next
      // expected nonce.
      const nonce = await rpc.getNonce(wallet.address).catch(() => 0);
      const { signature, publicKey } = signStakePayload({
        privateKeyHex: wallet.privateKey,
        from: wallet.address,
        amountSat,
        lockBlocks,
        nonce,
      });
      const r = (await rpc.request_raw("stake", [{
        from: wallet.address,
        amount_sat: amountSat,
        lock_blocks: lockBlocks,
        signature,
        public_key: publicKey,
        nonce,
      }])) as StakeResp;
      setToast(`Stake submitted — txid ${r.txid.slice(0, 12)}… (id #${r.stake_id})`);
      setAmountStr("");
      await refreshBalance();
    } catch (e) {
      setToast(`Stake failed: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setBusy(false);
      window.setTimeout(() => setToast(null), 6000);
    }
  };

  return (
    <div className="space-y-4">
      {!wallet && (
        <p className="text-xs text-mempool-orange font-mono bg-mempool-orange/10 border border-mempool-orange/30 rounded px-3 py-2">
          Connect a wallet to stake. Signing happens locally with the in-memory key from
          wallet-keystore — your private key never leaves the browser.
        </p>
      )}

      {/* Amount */}
      <div className="space-y-1.5">
        <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">Amount (OMNI)</label>
        <div className="flex gap-2">
          <input
            type="number"
            min="0"
            step="0.01"
            value={amountStr}
            onChange={(e) => setAmountStr(e.target.value)}
            placeholder="0.00"
            className="flex-1 bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-sm font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
          />
          <button
            type="button"
            disabled={availableSat === null || availableSat <= 0}
            onClick={() => availableSat !== null && setAmountStr((availableSat / SAT_PER_OMNI).toString())}
            className="px-3 py-2 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue disabled:opacity-40"
          >
            Max
          </button>
        </div>
        <div className="text-[11px] text-mempool-text-dim font-mono space-y-0.5">
          {balanceSat === null ? (
            <div>balance: —</div>
          ) : (
            <>
              <div>
                wallet: <span className="text-mempool-text">{fmtOmni(balanceSat)} OMNI</span>
                {stakedSat > 0 && (
                  <>  ·  staked: <span className="text-mempool-orange">{fmtOmni(stakedSat)} OMNI</span></>
                )}
              </div>
              <div>
                available: <span className="text-mempool-green">{fmtOmni(availableSat ?? 0)} OMNI</span>
              </div>
            </>
          )}
        </div>
      </div>

      {/* Lock duration slider */}
      <div className="space-y-2">
        <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
          Lock duration
        </label>
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-2">
          {LOCK_PRESETS.map((p) => {
            const active = days === p.days;
            return (
              <button
                key={p.days}
                type="button"
                onClick={() => setDays(p.days)}
                className={
                  "px-3 py-2.5 text-xs rounded border font-mono transition-colors " +
                  (active
                    ? "bg-mempool-blue/15 text-mempool-blue border-mempool-blue"
                    : "bg-mempool-bg text-mempool-text-dim border-mempool-border hover:text-mempool-text")
                }
              >
                <Clock className="inline w-3 h-3 mr-1 -mt-0.5" />
                {p.label}
                <span className="text-[10px] text-mempool-text-dim ml-1">({p.multiplierHint})</span>
              </button>
            );
          })}
        </div>
        <div className="text-[11px] text-mempool-text-dim font-mono">
          longer lock = higher RENT/day multiplier
        </div>
      </div>

      {/* Estimated reward */}
      <div className="bg-mempool-bg border border-mempool-border rounded p-3 space-y-1.5">
        <div className="flex items-center gap-2 mb-1">
          <TrendingUp className="w-4 h-4 text-mempool-green" />
          <span className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
            Estimated reward
          </span>
        </div>
        <Row label="amount tier" value={`${tier.toFixed(1)}× (≥${
          amountOmni >= 10_000 ? "10,000" :
          amountOmni >= 1_000  ? "1,000"  :
          amountOmni >= 100    ? "100"    : "0"} OMNI)`} />
        <Row label="duration multiplier" value={`${durationMult.toFixed(1)}×`} />
        <Row label="RENT / day" value={
          <span className="text-mempool-green">{repFmt.format(estRentPerDay)} RENT</span>
        } />
        <Row label="RENT over lock" value={
          <span className="text-mempool-green">{repFmt.format(estRentTotal)} RENT</span>
        } />
        <Row label="lock_blocks" value={`${fmtInt(lockBlocks)} blk · unlocks @ ${fmtInt(blockHeight + lockBlocks)}`} />
      </div>

      {availableSat !== null && amountSat > availableSat && (
        <p className="text-xs text-mempool-orange font-mono">
          Amount exceeds available ({fmtOmni(availableSat)} OMNI free, {fmtOmni(stakedSat)} already staked).
        </p>
      )}

      <button
        onClick={() => void doStake()}
        disabled={!canSubmit}
        className="w-full px-4 py-2.5 rounded bg-mempool-blue/15 text-mempool-blue border border-mempool-blue/40 hover:bg-mempool-blue/25 disabled:opacity-40 disabled:cursor-not-allowed text-sm font-medium uppercase tracking-wider"
      >
        {busy ? "Signing & broadcasting…" : "Stake OMNI"}
      </button>

      {toast && (
        <div className="fixed bottom-4 right-4 bg-mempool-bg-elev border border-mempool-border rounded px-4 py-2 text-xs text-mempool-text font-mono shadow-lg z-50">
          {toast}
        </div>
      )}
    </div>
  );
}

function Row({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="flex justify-between text-xs font-mono">
      <span className="text-mempool-text-dim">{label}</span>
      <span className="text-mempool-text">{value}</span>
    </div>
  );
}

// ── Tab 3: Top Stakers ────────────────────────────────────────────────────

function TopStakersTab() {
  const [sortBy, setSortBy] = useState<SortBy>("amount");
  const [rows, setRows] = useState<StakerRow[] | null>(null);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    setLoading(true);
    setErr(null);
    try {
      const r = (await rpc.request_raw(
        "getstakers",
        [{ sort_by: sortBy, limit: 50 }],
      )) as GetStakersResp | null;
      setRows(r?.stakers ?? []);
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
      setRows([]);
    } finally {
      setLoading(false);
    }
  }, [sortBy]);

  useEffect(() => { void refresh(); }, [refresh]);

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-2">
        <span className="text-[10px] uppercase tracking-wider text-mempool-text-dim">Sort by</span>
        {(["amount", "rent", "days"] as SortBy[]).map((k) => {
          const active = sortBy === k;
          return (
            <button
              key={k}
              onClick={() => setSortBy(k)}
              className={
                "px-3 py-1 text-xs rounded border font-mono " +
                (active
                  ? "bg-mempool-blue/15 text-mempool-blue border-mempool-blue"
                  : "bg-mempool-bg text-mempool-text-dim border-mempool-border hover:text-mempool-text")
              }
            >
              {k}
            </button>
          );
        })}
        <div className="flex-1" />
        {rows && rows.length > 0 && (
          <button
            onClick={() => {
              const csvRows = [
                ["rank", "address", "amount_omni", "days_locked", "rent_earned"].join(","),
                ...rows.map((r, i) => [
                  i + 1,
                  `"${r.address}"`,
                  (r.amount_sat / SAT_PER_OMNI).toFixed(8),
                  r.days_locked,
                  (r.rent_earned / 100).toFixed(2),
                ].join(",")),
              ].join("\n");
              const blob = new Blob([csvRows], { type: "text/csv" });
              const url = URL.createObjectURL(blob);
              const a = document.createElement("a");
              a.href = url; a.download = "omnibus-top-stakers.csv";
              a.click(); URL.revokeObjectURL(url);
            }}
            className="flex items-center gap-1.5 px-3 py-1 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-text font-mono"
          >
            ⬇ CSV
          </button>
        )}
        <button
          onClick={() => void refresh()}
          disabled={loading}
          className="flex items-center gap-1.5 px-3 py-1 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue disabled:opacity-50"
        >
          <RefreshCw className={`w-3.5 h-3.5 ${loading ? "animate-spin" : ""}`} />
          Refresh
        </button>
      </div>

      {err && <p className="text-xs text-mempool-orange font-mono">{err}</p>}
      {!err && rows && rows.length === 0 && (
        <p className="text-xs text-mempool-text-dim font-mono py-6 text-center">
          No stakers yet.
        </p>
      )}
      {rows && rows.length > 0 && (
        <div className="overflow-x-auto -mx-3 sm:mx-0">
          <table className="w-full min-w-[480px] text-xs font-mono">
            <thead className="sticky top-0 bg-mempool-bg-elev">
              <tr className="text-left text-mempool-text-dim uppercase tracking-wider">
                <th className="py-2 px-2 font-medium">#</th>
                <th className="py-2 px-2 font-medium">Address</th>
                <th className="py-2 px-2 font-medium text-right">Amount (OMNI)</th>
                <th className="py-2 px-2 font-medium text-right">Days locked</th>
                <th className="py-2 px-2 font-medium text-right">RENT earned</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r, i) => (
                <tr key={r.address + i} className="border-t border-mempool-border/40">
                  <td className="py-2 px-2 text-mempool-text-dim">{i + 1}</td>
                  <td className="py-2 px-2">
                    <button
                      onClick={() => { window.location.hash = `#/address/${r.address}`; }}
                      className="text-mempool-blue hover:underline"
                      title={r.address}
                    >
                      <AddressLabel address={r.address} showEmoji truncate={{ left: 8, right: 6 }} />
                    </button>
                  </td>
                  <td className="py-2 px-2 text-right text-mempool-text">{fmtOmni(r.amount_sat)}</td>
                  <td className="py-2 px-2 text-right text-mempool-text-dim">{fmtInt(r.days_locked)}</td>
                  <td className="py-2 px-2 text-right text-mempool-green">{fmtRent(r.rent_earned)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

// ── Tab 4: Activity (audit per-stake history) ────────────────────────────
//
// Lists every stake / unstake TX the chain remembers for the current wallet,
// computes a running stake balance from those TXs alone, then compares that
// against the live `getstake` result. If they don't match the user gets a
// loud warning so we never silently drift away from chain reality — exactly
// what the user asked for ("sync UI 100 % to chain reality").

function StakeActivityTab() {
  const wallet = useWallet();
  const [addrInput, setAddrInput] = useState<string>("");
  const effectiveAddress = wallet?.address ?? addrInput.trim();

  const [txs, setTxs] = useState<AddressHistoryTx[] | null>(null);
  const [chainStakeSat, setChainStakeSat] = useState<number | null>(null);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    if (!effectiveAddress) {
      setTxs(null);
      setChainStakeSat(null);
      return;
    }
    setLoading(true);
    setErr(null);
    try {
      // Fire both in parallel so the running total + chain truth come from
      // the same snapshot of chain state, minimising drift between "what the
      // history says" and "what getstake reports".
      const [histRaw, stakeResp] = await Promise.all([
        rpc.getAddressHistory(effectiveAddress),
        rpc.getStake(effectiveAddress),
      ]);
      const hist = histRaw as AddressHistoryResp | null;

      // Filter to stake / unstake TXs only. The backend tags these via
      // `inferTxKind` (kind === "stake") for op_return-prefixed sends.
      const filtered = (hist?.transactions ?? []).filter(
        (t) => t.kind === "stake",
      );
      // Sort oldest → newest so the running balance walks the timeline in
      // the right direction. Pending TXs (blockHeight === null) come last.
      filtered.sort((a, b) => {
        const ah = a.blockHeight ?? Number.MAX_SAFE_INTEGER;
        const bh = b.blockHeight ?? Number.MAX_SAFE_INTEGER;
        return ah - bh;
      });
      setTxs(filtered);

      const totalStaked = (stakeResp?.stakes ?? [])
        .filter((s) => s.status === "active" || s.status === "unbonding")
        .reduce((acc, s) => acc + (s.amount_sat ?? 0), 0);
      setChainStakeSat(totalStaked);
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
      setTxs([]);
      setChainStakeSat(null);
    } finally {
      setLoading(false);
    }
  }, [effectiveAddress]);

  useEffect(() => { void refresh(); }, [refresh]);

  // Walk TX list, classify by op_return, build per-row running total.
  // We can't read op_return from getaddresshistory directly, so we trust
  // the backend's `kind === "stake"` flag plus tx direction to figure out
  // intent: sent → either stake or unstake; we only know which by amount
  // sign. To stay safe we classify any "sent" stake-kind TX from this addr
  // as a stake (+amount), and "received" stake-kind TX (return-of-funds
  // from chain) as an unstake (-amount). This matches inferTxKind which
  // tags both `stake:` and `unstake:` op_return prefixes as kind="stake".
  const rows = useMemo(() => {
    const list = (txs ?? []).filter((t) => effectiveAddress.length > 0);
    let running = 0;
    return list.map((t) => {
      const isStake = t.direction === "sent";
      const delta = isStake ? t.amount : -t.amount;
      running += delta;
      return { tx: t, type: (isStake ? "Stake" : "Unstake") as "Stake" | "Unstake", delta, running };
    });
  }, [txs, effectiveAddress]);

  const computedRunning = rows.length > 0 ? rows[rows.length - 1].running : 0;
  const mismatch =
    chainStakeSat !== null &&
    txs !== null &&
    computedRunning !== chainStakeSat;

  return (
    <div className="space-y-4">
      {/* Address row (mirror MyStakesTab look) */}
      <div className="flex flex-wrap items-center gap-2">
        {wallet ? (
          <span className="text-xs text-mempool-text-dim font-mono truncate max-w-full">
            wallet: <span className="text-mempool-text break-all">{wallet.address}</span>
          </span>
        ) : (
          <input
            type="text"
            value={addrInput}
            onChange={(e) => setAddrInput(e.target.value)}
            placeholder="ob1q… (paste address to view stake history)"
            className="flex-1 min-w-0 sm:min-w-[280px] w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
          />
        )}
        {rows.length > 0 && (
          <button
            onClick={() => {
              const csvRows = [
                ["block", "type", "txid", "amount_omni", "running_stake_omni"].join(","),
                ...rows.map((r) => [
                  r.tx.blockHeight === null ? "pending" : r.tx.blockHeight,
                  r.type,
                  r.tx.txid,
                  (r.delta / SAT_PER_OMNI).toFixed(8),
                  (r.running / SAT_PER_OMNI).toFixed(8),
                ].join(",")),
              ].join("\n");
              const blob = new Blob([csvRows], { type: "text/csv" });
              const url = URL.createObjectURL(blob);
              const a = document.createElement("a");
              a.href = url; a.download = "omnibus-stake-activity.csv";
              a.click(); URL.revokeObjectURL(url);
            }}
            className="flex items-center gap-1.5 px-3 py-2 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-text font-mono"
          >
            ⬇ CSV
          </button>
        )}
        <button
          onClick={() => void refresh()}
          disabled={loading}
          className="flex items-center gap-1.5 px-3 py-2 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue disabled:opacity-50"
        >
          <RefreshCw className={`w-3.5 h-3.5 ${loading ? "animate-spin" : ""}`} />
          Refresh
        </button>
      </div>

      {/* Sync status — running total vs chain getstake */}
      {chainStakeSat !== null && txs !== null && (
        <div
          className={
            "flex items-center gap-2 rounded border px-3 py-2 text-xs font-mono " +
            (mismatch
              ? "bg-mempool-orange/10 border-mempool-orange/40 text-mempool-orange"
              : "bg-mempool-green/5 border-mempool-green/30 text-mempool-green")
          }
        >
          {mismatch ? (
            <>
              <AlertTriangle className="w-4 h-4 flex-shrink-0" />
              <span>
                Chain state out of sync — running total: {fmtOmni(computedRunning)} OMNI,
                {" "}current: {fmtOmni(chainStakeSat)} OMNI. Refresh or check pending TXs.
              </span>
            </>
          ) : (
            <span>
              Running total matches chain — {fmtOmni(chainStakeSat)} OMNI staked
              {" "}across {rows.length} TX{rows.length === 1 ? "" : "s"}.
            </span>
          )}
        </div>
      )}

      {err && <p className="text-xs text-mempool-orange font-mono">{err}</p>}

      {!err && txs && txs.length === 0 && (
        <p className="text-xs text-mempool-text-dim font-mono py-6 text-center">
          No stake / unstake TXs for this address yet.
        </p>
      )}

      {/* Activity table */}
      {rows.length > 0 && (
        <div className="overflow-x-auto -mx-3 sm:mx-0">
          <table className="w-full min-w-[560px] text-xs font-mono">
            <thead className="sticky top-0 bg-mempool-bg-elev">
              <tr className="text-left text-mempool-text-dim uppercase tracking-wider">
                <th className="py-2 px-2 font-medium">Block</th>
                <th className="py-2 px-2 font-medium">Type</th>
                <th className="py-2 px-2 font-medium">TXID</th>
                <th className="py-2 px-2 font-medium text-right">Amount (OMNI)</th>
                <th className="py-2 px-2 font-medium text-right">Running stake</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r, i) => (
                <tr key={r.tx.txid + i} className="border-t border-mempool-border/40">
                  <td className="py-2 px-2 text-mempool-text-dim">
                    {r.tx.blockHeight === null ? "pending" : fmtInt(r.tx.blockHeight)}
                  </td>
                  <td className="py-2 px-2">
                    <span
                      className={
                        "px-2 py-0.5 rounded border text-[10px] uppercase tracking-wider " +
                        (r.type === "Stake"
                          ? "bg-mempool-blue/15 text-mempool-blue border-mempool-blue/40"
                          : "bg-mempool-orange/15 text-mempool-orange border-mempool-orange/40")
                      }
                    >
                      {r.type}
                    </span>
                  </td>
                  <td className="py-2 px-2">
                    <a
                      href={`/blocks/${r.tx.txid}`}
                      className="text-mempool-blue hover:underline"
                      title={r.tx.txid}
                    >
                      {midTrunc(r.tx.txid, 10, 6)}
                    </a>
                  </td>
                  <td
                    className={
                      "py-2 px-2 text-right " +
                      (r.delta >= 0 ? "text-mempool-green" : "text-mempool-orange")
                    }
                  >
                    {r.delta >= 0 ? "+" : "−"}{fmtOmni(Math.abs(r.delta))}
                  </td>
                  <td className="py-2 px-2 text-right text-mempool-text">
                    {fmtOmni(r.running)}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

export default StakePage;

/**
 * GovernancePage.tsx — On-chain governance for OmniBus.
 *
 * Governance lets OMNI holders propose and vote on parameter changes:
 *   - Block reward adjustments
 *   - Difficulty targets
 *   - Validator ladder parameters (tier caps, staking minimums)
 *   - Protocol fee rates
 *
 * Backend RPCs (rpc_server.zig handlers):
 *   - getproposals   { filter: "active"|"all" }
 *   - getproposal    { proposal_id: number }
 *   - gov_propose    { from, title_hash, voting_blocks, quorum, note, signature, public_key, nonce }
 *   - gov_vote       { from, proposal_id, vote:"yes"|"no", tier:"OMNI", signature, public_key, nonce }
 *   - gov_execute    { proposal_id: number }
 *
 * Signing uses SHA256d + secp256k1 (same pattern as StakePage.tsx).
 * Canonical message formats must match rpc_server.zig verifiers exactly.
 */

import { useCallback, useEffect, useState } from "react";
import { subscribe as wsSubscribe } from "../../api/ws-bus";
import type { WsNewBlockEvent } from "../../types";
import {
  Scale,
  RefreshCw,
  CheckCircle,
  XCircle,
  Clock,
  Zap,
  ChevronDown,
  ChevronUp,
  AlertTriangle,
  Info,
} from "lucide-react";
import * as secp from "@noble/secp256k1";
import { sha256 } from "@noble/hashes/sha2";
import { hmac } from "@noble/hashes/hmac";
import { OmniBusRpcClient } from "../../api/rpc-client";
import { AddressLabel } from "../common/AddressLabel";
import { useWallet } from "../../api/use-wallet";
import { bytesToHex, hexToBytes } from "../../api/exchange-sign";

// ── noble/secp256k1 v2 HMAC init (copy from exchange-sign.ts) ─────────────

const sAny: unknown = secp;
{
  const s = sAny as Record<string, Record<string, unknown>>;
  const concatB = (...arrays: Uint8Array[]): Uint8Array => {
    let t = 0; for (const a of arrays) t += a.length;
    const o = new Uint8Array(t); let off = 0;
    for (const a of arrays) { o.set(a, off); off += a.length; }
    return o;
  };
  if (s?.etc && !s.etc.hmacSha256Sync)
    s.etc.hmacSha256Sync = (k: Uint8Array, ...m: Uint8Array[]) => hmac(sha256, k, concatB(...m));
  if (s?.utils && !s.utils.hmacSha256Sync)
    s.utils.hmacSha256Sync = (k: Uint8Array, ...m: Uint8Array[]) => hmac(sha256, k, concatB(...m));
}

const rpc = new OmniBusRpcClient();

// ── Constants ──────────────────────────────────────────────────────────────

const VOTING_PRESETS = [
  { blocks: 1440,  label: "~1 day",   hint: "1,440 blocks" },
  { blocks: 10080, label: "~1 week",  hint: "10,080 blocks" },
  { blocks: 43200, label: "~30 days", hint: "43,200 blocks" },
] as const;

// ── Types ──────────────────────────────────────────────────────────────────

type ProposalStatus = "voting" | "passed" | "rejected" | "expired" | "executed";

interface Proposal {
  id: number;
  proposer: string;
  title_hash: string;
  status: ProposalStatus;
  yes_weight: number;
  no_weight: number;
  quorum: number;
  voting_end_block: number;
  vote_count: number;
  // extended (getproposal only)
  note?: string;
  create_block?: number;
  executed?: boolean;
  executed_block?: number;
  action_kind?: string;
  action_u64?: number;
  action_bool?: boolean;
}

interface GetProposalsResp { proposals: Proposal[] }
interface GovProposeResp { status: string; txid: string; proposal_id: number; voting_end_block: number; quorum: number }
interface GovVoteResp { status: string; txid: string; vote: string }
interface GovExecuteResp { proposal_id: number; executed_block: number; action_kind: string; action_u64: number; action_bool: boolean; status: string }

type SubTab = "proposals" | "all" | "propose" | "vote";

// ── Format helpers ─────────────────────────────────────────────────────────

const intFmt = new Intl.NumberFormat("en-US");

function sha256Hex(text: string): string {
  const bytes = new TextEncoder().encode(text);
  const h = sha256(bytes);
  return bytesToHex(h);
}

// ── Signing (canonical — must match rpc_server.zig gov_ handlers) ──────────

function signGovPropose(args: {
  privateKeyHex: string;
  from: string;
  titleHash: string;
  votingBlocks: number;
  quorum: number;
  nonce: number;
}): { signature: string; publicKey: string } {
  const msg = `GOV_PROPOSE_V1\n${args.from}\n${args.titleHash}\n${args.votingBlocks}\n${args.quorum}\n${args.nonce}`;
  return signMessage(args.privateKeyHex, msg);
}

function signGovVote(args: {
  privateKeyHex: string;
  from: string;
  proposalId: number;
  vote: "yes" | "no";
  nonce: number;
}): { signature: string; publicKey: string } {
  const msg = `GOV_VOTE_V1\n${args.from}\n${args.proposalId}\n${args.vote}\n${args.nonce}`;
  return signMessage(args.privateKeyHex, msg);
}

function signMessage(privKeyHex: string, msg: string): { signature: string; publicKey: string } {
  const bytes = new TextEncoder().encode(msg);
  const h = sha256(sha256(bytes));
  const priv = hexToBytes(privKeyHex);
  const sig = secp.sign(h, priv, { lowS: true });
  const pub = secp.getPublicKey(priv, true);
  return { signature: bytesToHex(sig.toBytes()), publicKey: bytesToHex(pub) };
}

// ── Status badge helper ────────────────────────────────────────────────────

function StatusBadge({ status }: { status: ProposalStatus }) {
  const cls: Record<ProposalStatus, string> = {
    voting:   "bg-blue-500/20 text-blue-400 border-blue-500/40",
    passed:   "bg-green-500/20 text-green-400 border-green-500/40",
    rejected: "bg-red-500/20 text-red-400 border-red-500/40",
    expired:  "bg-gray-500/20 text-gray-400 border-gray-500/40",
    executed: "bg-purple-500/20 text-purple-400 border-purple-500/40",
  };
  const icon: Record<ProposalStatus, React.ReactNode> = {
    voting:   <Clock className="w-3 h-3 inline mr-1" />,
    passed:   <CheckCircle className="w-3 h-3 inline mr-1" />,
    rejected: <XCircle className="w-3 h-3 inline mr-1" />,
    expired:  <Clock className="w-3 h-3 inline mr-1" />,
    executed: <Zap className="w-3 h-3 inline mr-1" />,
  };
  return (
    <span className={`inline-flex items-center px-2 py-0.5 rounded border text-[10px] uppercase tracking-wider font-medium ${cls[status]}`}>
      {icon[status]}{status}
    </span>
  );
}

// ── Vote progress bar ──────────────────────────────────────────────────────

function VoteBar({ yes, no, quorum }: { yes: number; no: number; quorum: number }) {
  const total = yes + no;
  const yesPct = total > 0 ? (yes / total) * 100 : 0;
  const noPct  = total > 0 ? (no  / total) * 100 : 0;
  const quorumReached = total >= quorum;
  return (
    <div className="space-y-1">
      <div className="flex h-2 rounded overflow-hidden bg-mempool-border/30">
        <div className="bg-green-500/70 transition-all" style={{ width: `${yesPct}%` }} />
        <div className="bg-red-500/70 transition-all"   style={{ width: `${noPct}%`  }} />
      </div>
      <div className="flex justify-between text-[10px] font-mono text-mempool-text-dim">
        <span className="text-green-400">{intFmt.format(yes)} yes</span>
        <span className={quorumReached ? "text-green-400" : "text-mempool-text-dim"}>
          {intFmt.format(total)}/{intFmt.format(quorum)} quorum{quorumReached ? " ✓" : ""}
        </span>
        <span className="text-red-400">{intFmt.format(no)} no</span>
      </div>
    </div>
  );
}

// ── Proposal detail modal ──────────────────────────────────────────────────

function ProposalModal({
  proposal,
  blockHeight,
  onClose,
  onVote,
  onExecute,
  wallet,
}: {
  proposal: Proposal;
  blockHeight: number;
  onClose: () => void;
  onVote: (p: Proposal, v: "yes" | "no") => void;
  onExecute: (p: Proposal) => void;
  wallet: { address: string } | null;
}) {
  const blocksLeft = Math.max(0, proposal.voting_end_block - blockHeight);
  return (
    <div className="fixed inset-0 bg-black/60 flex items-center justify-center z-50 p-4">
      <div className="bg-mempool-bg-elev border border-mempool-border rounded-lg w-full max-w-lg mx-4 p-4 sm:p-5 space-y-4 max-h-[90vh] overflow-y-auto">
        {/* Header */}
        <div className="flex items-start gap-3">
          <Scale className="w-5 h-5 text-mempool-blue flex-shrink-0 mt-0.5" />
          <div className="flex-1 min-w-0">
            <div className="flex items-center gap-2 flex-wrap">
              <span className="text-xs font-mono text-mempool-text-dim">Proposal #{proposal.id}</span>
              <StatusBadge status={proposal.status} />
            </div>
            <p className="text-[10px] font-mono text-mempool-text-dim mt-1 break-all">
              title_hash: {proposal.title_hash}
            </p>
          </div>
          <button onClick={onClose} className="text-mempool-text-dim hover:text-mempool-text flex-shrink-0">
            <XCircle className="w-5 h-5" />
          </button>
        </div>

        {/* Info grid */}
        <div className="bg-mempool-bg border border-mempool-border rounded p-3 space-y-1.5">
          <Row label="Proposer"        value={
            <button onClick={() => { window.location.hash = `#/address/${proposal.proposer}`; }} className="font-mono text-mempool-blue hover:underline">
              <AddressLabel address={proposal.proposer} showEmoji truncate={{ left: 10, right: 8 }} />
            </button>
          } />
          <Row label="Created at block" value={proposal.create_block !== undefined ? intFmt.format(proposal.create_block) : "—"} />
          <Row label="Voting ends"      value={<>block {intFmt.format(proposal.voting_end_block)} <span className="text-mempool-text-dim">({blocksLeft > 0 ? `~${blocksLeft} blk left` : "ended"})</span></>} />
          <Row label="Quorum"           value={`${intFmt.format(proposal.quorum)} votes required`} />
          {proposal.action_kind && (
            <Row label="Action kind" value={<span className="text-mempool-orange font-mono">{proposal.action_kind}</span>} />
          )}
          {proposal.action_u64 !== undefined && (
            <Row label="Action value" value={<span className="font-mono">{intFmt.format(proposal.action_u64)}</span>} />
          )}
          {proposal.action_bool !== undefined && (
            <Row label="Action bool" value={proposal.action_bool ? "true" : "false"} />
          )}
          {proposal.executed_block !== undefined && (
            <Row label="Executed at block" value={<span className="text-purple-400 font-mono">{intFmt.format(proposal.executed_block)}</span>} />
          )}
        </div>

        {/* Note */}
        {proposal.note && (
          <div className="bg-mempool-bg border border-mempool-border rounded p-3">
            <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim mb-1">Note</div>
            <p className="text-xs text-mempool-text leading-relaxed whitespace-pre-wrap">{proposal.note}</p>
          </div>
        )}

        {/* Vote bar */}
        <div className="bg-mempool-bg border border-mempool-border rounded p-3 space-y-2">
          <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim">Votes</div>
          <VoteBar yes={proposal.yes_weight} no={proposal.no_weight} quorum={proposal.quorum} />
        </div>

        {/* Actions */}
        {proposal.status === "voting" && wallet && (
          <div className="flex gap-2">
            <button
              onClick={() => { onVote(proposal, "yes"); onClose(); }}
              className="flex-1 px-3 py-2.5 text-xs rounded bg-green-500/15 text-green-400 border border-green-500/40 hover:bg-green-500/25 font-medium uppercase tracking-wider"
            >
              Vote Yes
            </button>
            <button
              onClick={() => { onVote(proposal, "no"); onClose(); }}
              className="flex-1 px-3 py-2.5 text-xs rounded bg-red-500/15 text-red-400 border border-red-500/40 hover:bg-red-500/25 font-medium uppercase tracking-wider"
            >
              Vote No
            </button>
          </div>
        )}
        {proposal.status === "passed" && wallet && (
          <button
            onClick={() => { onExecute(proposal); onClose(); }}
            className="w-full px-3 py-2.5 text-xs rounded bg-purple-500/15 text-purple-400 border border-purple-500/40 hover:bg-purple-500/25 font-medium uppercase tracking-wider"
          >
            Execute proposal
          </button>
        )}
        {!wallet && (proposal.status === "voting" || proposal.status === "passed") && (
          <p className="text-[11px] text-mempool-text-dim font-mono text-center">
            Connect wallet to vote or execute
          </p>
        )}
      </div>
    </div>
  );
}

function Row({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="flex justify-between items-start gap-2 text-xs font-mono">
      <span className="text-mempool-text-dim flex-shrink-0">{label}</span>
      <span className="text-mempool-text text-right">{value}</span>
    </div>
  );
}

// ── Proposal row in table ──────────────────────────────────────────────────

function ProposalRow({
  proposal,
  blockHeight,
  onDetails,
  onVote,
  onExecute,
  wallet,
}: {
  proposal: Proposal;
  blockHeight: number;
  onDetails: (p: Proposal) => void;
  onVote: (p: Proposal, v: "yes" | "no") => void;
  onExecute: (p: Proposal) => void;
  wallet: { address: string } | null;
}) {
  const [expanded, setExpanded] = useState(false);
  const blocksLeft = Math.max(0, proposal.voting_end_block - blockHeight);

  return (
    <>
      <tr className="border-t border-mempool-border/40 hover:bg-mempool-bg/30 transition-colors">
        {/* ID */}
        <td className="py-2.5 px-2 text-mempool-text-dim font-mono text-[11px]">#{proposal.id}</td>
        {/* Status */}
        <td className="py-2.5 px-2"><StatusBadge status={proposal.status} /></td>
        {/* Proposer */}
        <td className="py-2.5 px-2 font-mono text-[11px]">
          <button onClick={() => { window.location.hash = `#/address/${proposal.proposer}`; }} className="text-mempool-blue hover:underline font-mono text-[11px]">
            <AddressLabel address={proposal.proposer} showEmoji truncate={{ left: 8, right: 6 }} />
          </button>
        </td>
        {/* Votes */}
        <td className="py-2.5 px-2 min-w-[120px]">
          <VoteBar yes={proposal.yes_weight} no={proposal.no_weight} quorum={proposal.quorum} />
        </td>
        {/* Ends */}
        <td className="py-2.5 px-2 font-mono text-[11px] text-mempool-text-dim">
          {proposal.status === "voting"
            ? (blocksLeft > 0 ? `~${intFmt.format(blocksLeft)} blk` : "ended")
            : `@ ${intFmt.format(proposal.voting_end_block)}`}
        </td>
        {/* Actions */}
        <td className="py-2.5 px-2">
          <div className="flex gap-1 flex-wrap">
            <button
              onClick={() => setExpanded(!expanded)}
              className="flex items-center gap-0.5 px-2 py-1 text-[10px] rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue"
            >
              {expanded ? <ChevronUp className="w-3 h-3" /> : <ChevronDown className="w-3 h-3" />}
              Details
            </button>
            {proposal.status === "voting" && wallet && (
              <>
                <button
                  onClick={() => onVote(proposal, "yes")}
                  className="px-2 py-1 text-[10px] rounded border border-green-500/40 text-green-400 hover:bg-green-500/15"
                >
                  Yes
                </button>
                <button
                  onClick={() => onVote(proposal, "no")}
                  className="px-2 py-1 text-[10px] rounded border border-red-500/40 text-red-400 hover:bg-red-500/15"
                >
                  No
                </button>
              </>
            )}
            {proposal.status === "passed" && wallet && (
              <button
                onClick={() => onExecute(proposal)}
                className="px-2 py-1 text-[10px] rounded border border-purple-500/40 text-purple-400 hover:bg-purple-500/15"
              >
                Execute
              </button>
            )}
          </div>
        </td>
      </tr>
      {expanded && (
        <tr className="border-t border-mempool-border/20">
          <td colSpan={6} className="px-3 pb-3 pt-0">
            <div className="bg-mempool-bg rounded border border-mempool-border/50 p-3 mt-1 space-y-2">
              <div className="text-[10px] font-mono text-mempool-text-dim break-all">
                <span className="text-mempool-text-dim">title_hash: </span>
                <span className="text-mempool-text">{proposal.title_hash}</span>
              </div>
              <div className="flex flex-wrap gap-3 text-[11px] font-mono">
                <span className="text-mempool-text-dim">
                  quorum: <span className="text-mempool-text">{intFmt.format(proposal.quorum)}</span>
                </span>
                <span className="text-mempool-text-dim">
                  votes: <span className="text-mempool-text">{intFmt.format(proposal.vote_count)}</span>
                </span>
                <span className="text-mempool-text-dim">
                  ends @ block: <span className="text-mempool-text">{intFmt.format(proposal.voting_end_block)}</span>
                </span>
              </div>
              <button
                onClick={() => onDetails(proposal)}
                className="text-[10px] text-mempool-blue hover:underline font-mono"
              >
                Open full modal →
              </button>
            </div>
          </td>
        </tr>
      )}
    </>
  );
}

// ── Proposals list (shared by "Active" and "All" tabs) ─────────────────────

function ProposalsTab({
  filter,
  blockHeight,
  wallet,
  onVote,
  onExecute,
  toast,
  setToast,
}: {
  filter: "active" | "all";
  blockHeight: number;
  wallet: { address: string; privateKey: string } | null;
  onVote: (p: Proposal, v: "yes" | "no") => void;
  onExecute: (p: Proposal) => void;
  toast: string | null;
  setToast: (t: string | null) => void;
}) {
  const [proposals, setProposals] = useState<Proposal[] | null>(null);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [modalProposal, setModalProposal] = useState<Proposal | null>(null);

  const refresh = useCallback(async () => {
    setLoading(true);
    setErr(null);
    try {
      const r = (await rpc.request_raw("getproposals", [{ filter }])) as GetProposalsResp | null;
      setProposals(r?.proposals ?? []);
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
      setProposals([]);
    } finally {
      setLoading(false);
    }
  }, [filter]);

  // Initial load + WS-driven refresh on new block, 60s fallback.
  useEffect(() => {
    let cancelled = false;
    const tick = async () => { if (!cancelled) await refresh(); };
    void tick();
    const unsub = wsSubscribe<WsNewBlockEvent>("new_block", () => { void tick(); });
    const id = window.setInterval(tick, 60_000);
    return () => { cancelled = true; window.clearInterval(id); unsub(); };
  }, [refresh]);

  // Fetch full proposal details for modal (getproposal returns extra fields)
  const openDetails = async (p: Proposal) => {
    try {
      const full = (await rpc.request_raw("getproposal", [{ proposal_id: p.id }])) as Proposal | null;
      setModalProposal(full ?? p);
    } catch {
      setModalProposal(p);
    }
  };

  return (
    <div className="space-y-4">
      {/* Toolbar */}
      <div className="flex items-center gap-2">
        <span className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
          {filter === "active" ? "Active proposals" : "All proposals"}
        </span>
        <div className="flex-1 h-px bg-mempool-border" />
        {proposals && proposals.length > 0 && (
          <button
            onClick={() => {
              const rows = [
                ["id", "status", "proposer", "yes_votes", "no_votes", "quorum", "voting_end_block", "vote_count"].join(","),
                ...proposals.map((p) => [
                  p.id,
                  p.status,
                  `"${p.proposer}"`,
                  p.yes_weight,
                  p.no_weight,
                  p.quorum,
                  p.voting_end_block,
                  p.vote_count,
                ].join(",")),
              ].join("\n");
              const blob = new Blob([rows], { type: "text/csv" });
              const url = URL.createObjectURL(blob);
              const a = document.createElement("a");
              a.href = url; a.download = "omnibus-proposals.csv";
              a.click(); URL.revokeObjectURL(url);
            }}
            className="flex items-center gap-1.5 px-3 py-1.5 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-text font-mono"
          >
            ⬇ CSV
          </button>
        )}
        <button
          onClick={() => void refresh()}
          disabled={loading}
          className="flex items-center gap-1.5 px-3 py-1.5 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue disabled:opacity-50"
        >
          <RefreshCw className={`w-3.5 h-3.5 ${loading ? "animate-spin" : ""}`} />
          Refresh
        </button>
      </div>

      {err && <p className="text-xs text-mempool-orange font-mono">{err}</p>}

      {!err && proposals && proposals.length === 0 && (
        <div className="py-10 text-center space-y-2">
          <Scale className="w-8 h-8 text-mempool-text-dim/40 mx-auto" />
          <p className="text-xs text-mempool-text-dim font-mono">
            {filter === "active"
              ? "No active proposals. Switch to the Propose tab to create one."
              : "No proposals on chain yet."}
          </p>
        </div>
      )}

      {proposals && proposals.length > 0 && (
        <div className="overflow-x-auto -mx-3 sm:mx-0">
          <table className="w-full min-w-[680px] text-xs">
            <thead className="sticky top-0 bg-mempool-bg-elev">
              <tr className="text-left text-mempool-text-dim uppercase tracking-wider text-[10px]">
                <th className="py-2 px-2 font-medium">ID</th>
                <th className="py-2 px-2 font-medium">Status</th>
                <th className="py-2 px-2 font-medium">Proposer</th>
                <th className="py-2 px-2 font-medium min-w-[140px]">Votes (yes/no/quorum)</th>
                <th className="py-2 px-2 font-medium">Voting ends</th>
                <th className="py-2 px-2 font-medium">Actions</th>
              </tr>
            </thead>
            <tbody>
              {proposals.map((p) => (
                <ProposalRow
                  key={p.id}
                  proposal={p}
                  blockHeight={blockHeight}
                  onDetails={openDetails}
                  onVote={onVote}
                  onExecute={onExecute}
                  wallet={wallet}
                />
              ))}
            </tbody>
          </table>
        </div>
      )}

      {/* Proposal detail modal */}
      {modalProposal && (
        <ProposalModal
          proposal={modalProposal}
          blockHeight={blockHeight}
          onClose={() => setModalProposal(null)}
          onVote={onVote}
          onExecute={onExecute}
          wallet={wallet}
        />
      )}

      {toast && (
        <div className="fixed bottom-4 right-4 bg-mempool-bg-elev border border-mempool-border rounded px-4 py-2 text-xs text-mempool-text font-mono shadow-lg z-50">
          {toast}
        </div>
      )}
    </div>
  );
}

// ── Propose tab ────────────────────────────────────────────────────────────

function ProposeTab({
  wallet,
}: {
  wallet: { address: string; privateKey: string } | null;
}) {
  const [title, setTitle] = useState("");
  const [note, setNote]   = useState("");
  const [votingBlocks, setVotingBlocks] = useState<number>(1440);
  const [quorum, setQuorum] = useState<string>("100");
  const [busy, setBusy] = useState(false);
  const [toast, setToast] = useState<string | null>(null);

  const titleHash = title.trim().length > 0 ? sha256Hex(title.trim()) : null;
  const quorumNum = parseInt(quorum, 10) || 0;
  const canSubmit = !!wallet && title.trim().length > 0 && quorumNum > 0 && !busy;

  const doPropose = async () => {
    if (!wallet) { setToast("Connect wallet to propose"); return; }
    if (!titleHash) { setToast("Enter a proposal title"); return; }
    setBusy(true);
    try {
      const nonceResp = await rpc.request_raw("getnonce", [wallet.address]) as
        { nonce?: number } | number | null;
      const nonce = typeof nonceResp === "number" ? nonceResp : (nonceResp?.nonce ?? 0);
      const { signature, publicKey } = signGovPropose({
        privateKeyHex: wallet.privateKey,
        from: wallet.address,
        titleHash,
        votingBlocks,
        quorum: quorumNum,
        nonce,
      });
      const r = (await rpc.request_raw("gov_propose", [{
        from: wallet.address,
        title_hash: titleHash,
        voting_blocks: votingBlocks,
        quorum: quorumNum,
        note: note.trim(),
        signature,
        public_key: publicKey,
        nonce,
      }])) as GovProposeResp;
      setToast(
        `Proposal #${r.proposal_id} submitted — txid ${r.txid.slice(0, 12)}… — voting ends @ block ${intFmt.format(r.voting_end_block)}`
      );
      setTitle("");
      setNote("");
    } catch (e) {
      setToast(`Propose failed: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setBusy(false);
      window.setTimeout(() => setToast(null), 6000);
    }
  };

  return (
    <div className="space-y-4 max-w-lg">
      {!wallet && (
        <p className="text-xs text-mempool-orange font-mono bg-mempool-orange/10 border border-mempool-orange/30 rounded px-3 py-2">
          Connect a wallet to create a proposal. Signing happens locally — your private key never leaves the browser.
        </p>
      )}

      {/* What governance can change */}
      <div className="bg-mempool-bg border border-mempool-border rounded p-3 flex gap-2">
        <Info className="w-4 h-4 text-mempool-blue flex-shrink-0 mt-0.5" />
        <p className="text-[11px] text-mempool-text-dim leading-relaxed">
          Governance proposals can change: <span className="text-mempool-text">block rewards</span>,{" "}
          <span className="text-mempool-text">difficulty targets</span>,{" "}
          <span className="text-mempool-text">validator tier caps &amp; staking minimums</span>,{" "}
          and <span className="text-mempool-text">protocol fee rates</span>.
          Proposals that pass quorum and majority YES are executed on-chain after the voting period.
        </p>
      </div>

      {/* Title */}
      <div className="space-y-1.5">
        <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
          Proposal title <span className="text-mempool-orange">*</span>
        </label>
        <input
          type="text"
          value={title}
          onChange={(e) => setTitle(e.target.value)}
          placeholder="e.g. Reduce block reward to 5 OMNI from block 500000"
          maxLength={256}
          className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
        />
        {titleHash && (
          <p className="text-[10px] font-mono text-mempool-text-dim break-all">
            sha256: <span className="text-mempool-text">{titleHash}</span>
          </p>
        )}
      </div>

      {/* Note */}
      <div className="space-y-1.5">
        <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
          Note / rationale
        </label>
        <textarea
          value={note}
          onChange={(e) => setNote(e.target.value)}
          rows={4}
          maxLength={1024}
          placeholder="Describe the rationale, expected impact, references…"
          className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue resize-y"
        />
      </div>

      {/* Voting period */}
      <div className="space-y-2">
        <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
          Voting period
        </label>
        <div className="grid grid-cols-3 gap-2">
          {VOTING_PRESETS.map((p) => {
            const active = votingBlocks === p.blocks;
            return (
              <button
                key={p.blocks}
                type="button"
                onClick={() => setVotingBlocks(p.blocks)}
                className={
                  "px-3 py-2.5 text-xs rounded border font-mono transition-colors text-center " +
                  (active
                    ? "bg-mempool-blue/15 text-mempool-blue border-mempool-blue"
                    : "bg-mempool-bg text-mempool-text-dim border-mempool-border hover:text-mempool-text")
                }
              >
                <span className="block font-semibold">{p.label}</span>
                <span className="text-[10px] text-mempool-text-dim">{p.hint}</span>
              </button>
            );
          })}
        </div>
      </div>

      {/* Quorum */}
      <div className="space-y-1.5">
        <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
          Quorum (min total votes)
        </label>
        <input
          type="number"
          min="1"
          step="1"
          value={quorum}
          onChange={(e) => setQuorum(e.target.value)}
          className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-sm font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
          placeholder="100"
        />
        <p className="text-[10px] text-mempool-text-dim font-mono">
          Minimum yes+no vote count to make the result binding.
        </p>
      </div>

      <button
        onClick={() => void doPropose()}
        disabled={!canSubmit}
        className="w-full px-4 py-2.5 rounded bg-mempool-blue/15 text-mempool-blue border border-mempool-blue/40 hover:bg-mempool-blue/25 disabled:opacity-40 disabled:cursor-not-allowed text-sm font-medium uppercase tracking-wider"
      >
        {busy ? "Signing & broadcasting…" : "Submit proposal"}
      </button>

      {toast && (
        <div className="fixed bottom-4 right-4 bg-mempool-bg-elev border border-mempool-border rounded px-4 py-2 text-xs text-mempool-text font-mono shadow-lg z-50 max-w-sm">
          {toast}
        </div>
      )}
    </div>
  );
}

// ── Vote tab (vote by proposal ID) ─────────────────────────────────────────

function VoteTab({
  wallet,
}: {
  wallet: { address: string; privateKey: string } | null;
}) {
  const [proposalIdStr, setProposalIdStr] = useState("");
  const [fetchedProposal, setFetchedProposal] = useState<Proposal | null>(null);
  const [fetching, setFetching] = useState(false);
  const [fetchErr, setFetchErr] = useState<string | null>(null);
  const [vote, setVote] = useState<"yes" | "no" | null>(null);
  const [busy, setBusy] = useState(false);
  const [toast, setToast] = useState<string | null>(null);

  const doFetch = async () => {
    const id = parseInt(proposalIdStr, 10);
    if (isNaN(id)) { setFetchErr("Enter a valid proposal ID"); return; }
    setFetching(true);
    setFetchErr(null);
    setFetchedProposal(null);
    setVote(null);
    try {
      const r = (await rpc.request_raw("getproposal", [{ proposal_id: id }])) as Proposal | null;
      if (!r) { setFetchErr("Proposal not found"); return; }
      setFetchedProposal(r);
    } catch (e) {
      setFetchErr(e instanceof Error ? e.message : String(e));
    } finally {
      setFetching(false);
    }
  };

  const doVote = async () => {
    if (!wallet) { setToast("Connect wallet to vote"); return; }
    if (!fetchedProposal) { setToast("Fetch a proposal first"); return; }
    if (!vote) { setToast("Select Yes or No"); return; }
    setBusy(true);
    try {
      const nonceResp = await rpc.request_raw("getnonce", [wallet.address]) as
        { nonce?: number } | number | null;
      const nonce = typeof nonceResp === "number" ? nonceResp : (nonceResp?.nonce ?? 0);
      const { signature, publicKey } = signGovVote({
        privateKeyHex: wallet.privateKey,
        from: wallet.address,
        proposalId: fetchedProposal.id,
        vote,
        nonce,
      });
      const r = (await rpc.request_raw("gov_vote", [{
        from: wallet.address,
        proposal_id: fetchedProposal.id,
        vote,
        tier: "OMNI",
        signature,
        public_key: publicKey,
        nonce,
      }])) as GovVoteResp;
      setToast(`Vote "${r.vote}" submitted — txid ${r.txid.slice(0, 12)}…`);
      // Re-fetch to show updated counts
      void doFetch();
    } catch (e) {
      setToast(`Vote failed: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setBusy(false);
      window.setTimeout(() => setToast(null), 6000);
    }
  };

  return (
    <div className="space-y-4 max-w-lg">
      {!wallet && (
        <p className="text-xs text-mempool-orange font-mono bg-mempool-orange/10 border border-mempool-orange/30 rounded px-3 py-2">
          Connect wallet to cast a vote. Signing happens locally in the browser.
        </p>
      )}

      {/* Lookup */}
      <div className="space-y-1.5">
        <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
          Proposal ID
        </label>
        <div className="flex gap-2">
          <input
            type="number"
            min="1"
            step="1"
            value={proposalIdStr}
            onChange={(e) => setProposalIdStr(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && void doFetch()}
            placeholder="e.g. 42"
            className="flex-1 bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-sm font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
          />
          <button
            onClick={() => void doFetch()}
            disabled={fetching}
            className="px-4 py-2 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue disabled:opacity-50"
          >
            {fetching ? "…" : "Load"}
          </button>
        </div>
        {fetchErr && <p className="text-xs text-mempool-orange font-mono">{fetchErr}</p>}
      </div>

      {/* Proposal card */}
      {fetchedProposal && (
        <div className="bg-mempool-bg border border-mempool-border rounded p-4 space-y-3">
          <div className="flex items-center gap-2 flex-wrap">
            <span className="text-xs font-mono text-mempool-text-dim">#{fetchedProposal.id}</span>
            <StatusBadge status={fetchedProposal.status} />
          </div>
          <div className="text-[10px] font-mono text-mempool-text-dim break-all">
            title_hash: <span className="text-mempool-text">{fetchedProposal.title_hash}</span>
          </div>
          {fetchedProposal.note && (
            <p className="text-xs text-mempool-text leading-relaxed">{fetchedProposal.note}</p>
          )}
          <VoteBar yes={fetchedProposal.yes_weight} no={fetchedProposal.no_weight} quorum={fetchedProposal.quorum} />

          {fetchedProposal.status !== "voting" && (
            <p className="text-xs text-mempool-text-dim font-mono">
              <AlertTriangle className="w-3.5 h-3.5 inline mr-1 text-mempool-orange" />
              Voting is closed (status: {fetchedProposal.status}).
            </p>
          )}

          {fetchedProposal.status === "voting" && wallet && (
            <div className="space-y-3">
              <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
                Cast your vote (tier: OMNI)
              </div>
              <div className="flex gap-2">
                <button
                  onClick={() => setVote("yes")}
                  className={
                    "flex-1 px-3 py-2.5 text-xs rounded border font-medium uppercase tracking-wider transition-colors " +
                    (vote === "yes"
                      ? "bg-green-500/25 text-green-400 border-green-500"
                      : "bg-green-500/10 text-green-400 border-green-500/40 hover:bg-green-500/20")
                  }
                >
                  {vote === "yes" ? "✓ " : ""}Yes
                </button>
                <button
                  onClick={() => setVote("no")}
                  className={
                    "flex-1 px-3 py-2.5 text-xs rounded border font-medium uppercase tracking-wider transition-colors " +
                    (vote === "no"
                      ? "bg-red-500/25 text-red-400 border-red-500"
                      : "bg-red-500/10 text-red-400 border-red-500/40 hover:bg-red-500/20")
                  }
                >
                  {vote === "no" ? "✓ " : ""}No
                </button>
              </div>
              <button
                onClick={() => void doVote()}
                disabled={!vote || busy}
                className="w-full px-4 py-2.5 rounded bg-mempool-blue/15 text-mempool-blue border border-mempool-blue/40 hover:bg-mempool-blue/25 disabled:opacity-40 disabled:cursor-not-allowed text-sm font-medium uppercase tracking-wider"
              >
                {busy ? "Signing & broadcasting…" : `Confirm vote ${vote ? `"${vote}"` : ""}`}
              </button>
            </div>
          )}
        </div>
      )}

      {toast && (
        <div className="fixed bottom-4 right-4 bg-mempool-bg-elev border border-mempool-border rounded px-4 py-2 text-xs text-mempool-text font-mono shadow-lg z-50 max-w-sm">
          {toast}
        </div>
      )}
    </div>
  );
}

// ── Root component ─────────────────────────────────────────────────────────

export function GovernancePage() {
  const wallet = useWallet();
  const [tab, setTab] = useState<SubTab>("proposals");
  const [blockHeight, setBlockHeight] = useState<number>(0);

  // Shared toast + vote/execute callbacks so proposals list and modal
  // both surface results in a single place.
  const [sharedToast, setSharedToast] = useState<string | null>(null);
  const [voteBusy, setVoteBusy] = useState(false);
  const [executeBusy, setExecuteBusy] = useState(false);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const h = await rpc.getBlockCount();
        if (!cancelled) setBlockHeight(h);
      } catch { /* ignore */ }
    })();
    const unsub = wsSubscribe<WsNewBlockEvent>("new_block", (ev) => {
      setBlockHeight(ev.height);
    });
    const id = window.setInterval(async () => {
      try {
        const h = await rpc.getBlockCount();
        if (!cancelled) setBlockHeight(h);
      } catch { /* ignore */ }
    }, 60_000);
    return () => { cancelled = true; window.clearInterval(id); unsub(); };
  }, []);

  const handleVote = async (proposal: Proposal, vote: "yes" | "no") => {
    if (!wallet) { setSharedToast("Connect wallet to vote"); return; }
    if (proposal.status !== "voting") { setSharedToast("Proposal is not in voting status"); return; }
    setVoteBusy(true);
    try {
      const nonceResp = await rpc.request_raw("getnonce", [wallet.address]) as
        { nonce?: number } | number | null;
      const nonce = typeof nonceResp === "number" ? nonceResp : (nonceResp?.nonce ?? 0);
      const { signature, publicKey } = signGovVote({
        privateKeyHex: wallet.privateKey,
        from: wallet.address,
        proposalId: proposal.id,
        vote,
        nonce,
      });
      const r = (await rpc.request_raw("gov_vote", [{
        from: wallet.address,
        proposal_id: proposal.id,
        vote,
        tier: "OMNI",
        signature,
        public_key: publicKey,
        nonce,
      }])) as GovVoteResp;
      setSharedToast(`Vote "${r.vote}" on proposal #${proposal.id} — txid ${r.txid.slice(0, 12)}…`);
    } catch (e) {
      setSharedToast(`Vote failed: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setVoteBusy(false);
      window.setTimeout(() => setSharedToast(null), 6000);
    }
  };

  const handleExecute = async (proposal: Proposal) => {
    if (proposal.status !== "passed") { setSharedToast("Proposal has not passed yet"); return; }
    setExecuteBusy(true);
    try {
      const r = (await rpc.request_raw("gov_execute", [{ proposal_id: proposal.id }])) as GovExecuteResp;
      setSharedToast(
        `Proposal #${r.proposal_id} executed at block ${intFmt.format(r.executed_block)} — action: ${r.action_kind}`
      );
    } catch (e) {
      setSharedToast(`Execute failed: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setExecuteBusy(false);
      window.setTimeout(() => setSharedToast(null), 6000);
    }
  };

  // Suppress "unused" warnings from busy states (they gate UI in child via toast)
  void voteBusy; void executeBusy;

  return (
    <section className="bg-mempool-bg-elev rounded-lg p-3 sm:p-4 border border-mempool-border backdrop-blur-sm">
      {/* Header */}
      <div className="flex items-center gap-2 sm:gap-3 mb-4">
        <Scale className="w-5 h-5 text-mempool-blue flex-shrink-0" />
        <h2 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
          Governance
        </h2>
        <div className="flex-1 h-px bg-mempool-border" />
        <span className="text-[10px] sm:text-xs text-mempool-text-dim font-mono whitespace-nowrap">
          height {intFmt.format(blockHeight)}
        </span>
      </div>

      {/* Sub-tab bar */}
      <div className="flex gap-1 border-b border-mempool-border mb-4 overflow-x-auto scrollbar-none">
        {([
          { id: "proposals", label: "Active" },
          { id: "all",       label: "All proposals" },
          { id: "propose",   label: "Propose" },
          { id: "vote",      label: "Vote by ID" },
        ] as { id: SubTab; label: string }[]).map((t) => {
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

      {/* Tab content */}
      {tab === "proposals" && (
        <ProposalsTab
          filter="active"
          blockHeight={blockHeight}
          wallet={wallet}
          onVote={handleVote}
          onExecute={handleExecute}
          toast={sharedToast}
          setToast={setSharedToast}
        />
      )}
      {tab === "all" && (
        <ProposalsTab
          filter="all"
          blockHeight={blockHeight}
          wallet={wallet}
          onVote={handleVote}
          onExecute={handleExecute}
          toast={sharedToast}
          setToast={setSharedToast}
        />
      )}
      {tab === "propose" && <ProposeTab wallet={wallet} />}
      {tab === "vote"    && <VoteTab    wallet={wallet} />}

      {/* Shared toast (from handleVote / handleExecute) */}
      {sharedToast && tab !== "proposals" && tab !== "all" && (
        <div className="fixed bottom-4 right-4 bg-mempool-bg-elev border border-mempool-border rounded px-4 py-2 text-xs text-mempool-text font-mono shadow-lg z-50 max-w-sm">
          {sharedToast}
        </div>
      )}
    </section>
  );
}

export default GovernancePage;

#!/usr/bin/env node
// _orchestrator.mjs — Master orchestrator: runs 4 worker groups in parallel,
// aggregates results into JSON + markdown summary.
//
// Usage:
//   node test-scripts/_orchestrator.mjs --chain testnet
//   node test-scripts/_orchestrator.mjs --chain testnet --skip-stress
//
// Output:
//   orchestrator-report-<unix>.json
//   orchestrator-report-<unix>.md
//
// Exit code: 0 if all groups passed, 1 if any group failed.

import { spawn } from "node:child_process";
import { writeFileSync, existsSync } from "node:fs";
import { argv, exit } from "node:process";
import { Worker, isMainThread, parentPort, workerData } from "node:worker_threads";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __filename = fileURLToPath(import.meta.url);
const __dirname  = dirname(__filename);

// --- argv ---
const ARGS = argv.slice(2);
function arg(name, fallback) {
    const i = ARGS.indexOf(name);
    return i >= 0 && ARGS[i + 1] ? ARGS[i + 1] : fallback;
}
const CHAIN = arg("--chain", "testnet");
const SKIP_STRESS = ARGS.includes("--skip-stress");
const SKIP_FLOW   = ARGS.includes("--skip-flows");
const SKIP_HEALTH = ARGS.includes("--skip-health");

// --- worker code (re-entrant via worker_threads) ---
if (!isMainThread) {
    const { name, kind, items, chain } = workerData;
    const results = [];
    (async () => {
        for (const it of items) {
            const start = Date.now();
            const res = await runOne(it, kind, chain);
            res.duration_ms = Date.now() - start;
            results.push(res);
            parentPort.postMessage({ type: "progress", worker: name, item: it, ok: res.ok });
        }
        parentPort.postMessage({ type: "done", worker: name, results });
    })();
}

function runOne(item, kind, chain) {
    return new Promise((resolve) => {
        let cmd, args;
        if (kind === "bash") {
            cmd  = "bash";
            args = [join(__dirname, item), "--no-color"];
        } else if (kind === "node") {
            cmd  = "node";
            args = [join(__dirname, item), "--chain", chain];
        } else if (kind === "health") {
            cmd  = "bash";
            args = [join(__dirname, "_vps-health.sh"), "--no-color"];
        }
        const env = { ...process.env, CHAIN: chain, NO_COLOR: "1" };
        const p = spawn(cmd, args, { env, cwd: dirname(__dirname) });
        let stdout = "", stderr = "";
        p.stdout.on("data", (d) => (stdout += d.toString()));
        p.stderr.on("data", (d) => (stderr += d.toString()));
        p.on("close", (code) => {
            const passMatch = stdout.match(/pass:\s*(\d+)/);
            const failMatch = stdout.match(/fail:\s*(\d+)/);
            const skipMatch = stdout.match(/skip:\s*(\d+)/);
            resolve({
                item,
                kind,
                ok: code === 0,
                exit_code: code,
                pass: passMatch ? parseInt(passMatch[1], 10) : 0,
                fail: failMatch ? parseInt(failMatch[1], 10) : 0,
                skip: skipMatch ? parseInt(skipMatch[1], 10) : 0,
                stderr_tail: stderr.split("\n").slice(-3).join(" | "),
            });
        });
        p.on("error", (e) => resolve({ item, kind, ok: false, error: e.message }));
    });
}

// --- main thread orchestration ---
if (isMainThread) {
    const groups = [];
    if (!SKIP_FLOW) {
        // Read-only RPC suite (01-12)
        groups.push({
            name: "rpc-readonly",
            kind: "bash",
            items: Array.from({ length: 12 }, (_, i) => {
                const n = String(i + 1).padStart(2, "0");
                const map = {
                    "01": "01-chain-basic.sh",
                    "02": "02-reputation.sh",
                    "03": "03-stake-validators.sh",
                    "04": "04-agents.sh",
                    "05": "05-names.sh",
                    "06": "06-exchange.sh",
                    "07": "07-grid.sh",
                    "08": "08-htlc-swap.sh",
                    "09": "09-oracle.sh",
                    "10": "10-notarize-sub.sh",
                    "11": "11-escrow-channels.sh",
                    "12": "12-governance.sh",
                };
                return map[n];
            }).filter(Boolean),
        });
    }
    if (!SKIP_STRESS) {
        groups.push({
            name: "stress",
            kind: "node",
            items: ["13-dex-multichain-stress.mjs", "14-ns-stress.mjs", "15-htlc-stress.mjs"],
        });
    }
    if (!SKIP_FLOW) {
        groups.push({
            name: "flows",
            kind: "node",
            items: ["23-multiwallet-trade.mjs", "24-multiwallet-stake.mjs", "30-multiwallet-full-stress.mjs"]
                .filter(f => existsSync(join(__dirname, f))),
        });
    }
    if (!SKIP_HEALTH) {
        groups.push({ name: "health", kind: "health", items: ["_vps-health.sh"] });
    }

    console.log(`▶  orchestrator chain=${CHAIN} groups=${groups.length}`);
    const t0 = Date.now();
    const promises = groups.map(g => new Promise((resolve) => {
        const w = new Worker(__filename, { workerData: { ...g, chain: CHAIN } });
        const collected = [];
        w.on("message", (m) => {
            if (m.type === "progress") {
                console.log(`  [${m.worker}] ${m.ok ? "OK  " : "FAIL"} ${m.item}`);
            } else if (m.type === "done") {
                collected.push(...m.results);
                resolve({ name: g.name, results: collected });
            }
        });
        w.on("error", (e) => resolve({ name: g.name, results: [{ item: "<worker>", ok: false, error: e.message }] }));
    }));

    const groupResults = await Promise.all(promises);
    const elapsed = ((Date.now() - t0) / 1000).toFixed(1);

    // Aggregate
    let totalPass = 0, totalFail = 0, totalSkip = 0, totalGroupsFailed = 0;
    for (const g of groupResults) {
        for (const r of g.results) {
            totalPass += r.pass || 0;
            totalFail += r.fail || 0;
            totalSkip += r.skip || 0;
            if (!r.ok) totalGroupsFailed++;
        }
    }

    const ts = Math.floor(Date.now() / 1000);
    const json = { chain: CHAIN, elapsed_s: parseFloat(elapsed), totals: { pass: totalPass, fail: totalFail, skip: totalSkip }, groups: groupResults };
    writeFileSync(`orchestrator-report-${ts}.json`, JSON.stringify(json, null, 2));

    let md = `# Orchestrator Report — ${new Date().toISOString()}\n\nchain: \`${CHAIN}\`  •  elapsed: ${elapsed}s\n\n`;
    md += `**Totals:** pass ${totalPass} · fail ${totalFail} · skip ${totalSkip}\n\n`;
    for (const g of groupResults) {
        md += `## ${g.name}\n\n| item | ok | pass | fail | skip | duration |\n|---|---|---|---|---|---|\n`;
        for (const r of g.results) {
            md += `| ${r.item} | ${r.ok ? "✓" : "✗"} | ${r.pass || 0} | ${r.fail || 0} | ${r.skip || 0} | ${r.duration_ms || "?"}ms |\n`;
        }
        md += "\n";
    }
    writeFileSync(`orchestrator-report-${ts}.md`, md);

    console.log(`\n✔ done in ${elapsed}s  ·  pass=${totalPass} fail=${totalFail} skip=${totalSkip}`);
    console.log(`  reports: orchestrator-report-${ts}.{json,md}`);
    exit(totalFail > 0 || totalGroupsFailed > 0 ? 1 : 0);
}

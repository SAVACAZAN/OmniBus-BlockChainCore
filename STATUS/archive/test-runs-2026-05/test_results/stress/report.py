#!/usr/bin/env python3
# =============================================================================
# report.py - Aggregate stress test CSVs into REPORT.md and REPORT.html
# =============================================================================
# Usage : python report.py --date 2026-04-25
#         python report.py --root . --date 2026-04-25
# Reads : All *.csv and *.log under <root>/<date>/
# Writes: <root>/<date>/REPORT.md and <root>/<date>/REPORT.html
# =============================================================================
import argparse
import csv
import datetime as dt
import glob
import html
import os
import re
import statistics
import sys
from pathlib import Path


# --------------------------- helpers ---------------------------

def parse_iso(ts):
    try:
        return dt.datetime.fromisoformat(ts.replace('Z', '+00:00'))
    except Exception:
        return None


def safe_float(x):
    try:
        return float(x)
    except Exception:
        return None


def safe_int(x):
    try:
        if x is None or x == '' or x == 'NA':
            return None
        return int(float(x))
    except Exception:
        return None


def percentile(data, p):
    if not data:
        return 0.0
    s = sorted(data)
    k = (len(s) - 1) * (p / 100.0)
    f = int(k)
    c = min(f + 1, len(s) - 1)
    if f == c:
        return s[f]
    return s[f] + (s[c] - s[f]) * (k - f)


def read_csv(path):
    with open(path, 'r', encoding='utf-8', errors='replace', newline='') as f:
        rdr = csv.DictReader(f)
        return list(rdr)


# --------------------------- analyzers ---------------------------

def analyze_rpc(rows):
    """Aggregate latency by method + count statuses."""
    by_method = {}
    statuses = {}
    for r in rows:
        m = r.get('method', '?')
        st = r.get('status', '?')
        lat = safe_float(r.get('latency_ms'))
        by_method.setdefault(m, []).append(lat if lat is not None else 0.0)
        statuses[st] = statuses.get(st, 0) + 1
    summary = {}
    for m, lats in by_method.items():
        if not lats:
            continue
        summary[m] = {
            'count':  len(lats),
            'avg_ms': statistics.fmean(lats),
            'min_ms': min(lats),
            'max_ms': max(lats),
            'p95_ms': percentile(lats, 95),
            'p99_ms': percentile(lats, 99),
        }
    return summary, statuses


def analyze_blocks(rows):
    """Block production rate + stalls."""
    heights, times = [], []
    stalls = 0
    for r in rows:
        h = safe_int(r.get('height'))
        t = parse_iso(r.get('timestamp', ''))
        if h is not None and t is not None:
            heights.append(h)
            times.append(t)
        if r.get('stalled') == '1':
            stalls += 1
    if len(heights) < 2:
        return {'samples': len(heights), 'stall_ticks': stalls}
    span_sec = (times[-1] - times[0]).total_seconds()
    total = heights[-1] - heights[0]
    bps = total / span_sec if span_sec > 0 else 0.0
    return {
        'samples':      len(heights),
        'first_height': heights[0],
        'last_height':  heights[-1],
        'delta':        total,
        'duration_min': span_sec / 60.0,
        'blocks_per_min': bps * 60,
        'blocks_per_hour': bps * 3600,
        'stall_ticks':  stalls,
    }


def analyze_metrics(rows):
    """Memory growth across run = leak signal."""
    rams, cpus, handles, threads, disks, times = [], [], [], [], [], []
    for r in rows:
        t = parse_iso(r.get('ts', ''))
        if t is None:
            continue
        ram = safe_float(r.get('ram_mb'))
        if ram is None or ram == 0:
            continue  # node was down for this tick
        rams.append(ram)
        times.append(t)
        if (v := safe_float(r.get('cpu_sec')))   is not None: cpus.append(v)
        if (v := safe_int(r.get('handles')))     is not None: handles.append(v)
        if (v := safe_int(r.get('threads')))     is not None: threads.append(v)
        if (v := safe_float(r.get('disk_mb')))   is not None: disks.append(v)
    if not rams:
        return {'samples': 0}
    return {
        'samples':       len(rams),
        'ram_first_mb':  rams[0],
        'ram_last_mb':   rams[-1],
        'ram_max_mb':    max(rams),
        'ram_growth_mb': rams[-1] - rams[0],
        'cpu_total_sec': cpus[-1] if cpus else 0,
        'handles_max':   max(handles) if handles else 0,
        'threads_max':   max(threads) if threads else 0,
        'disk_first_mb': disks[0]  if disks else 0,
        'disk_last_mb':  disks[-1] if disks else 0,
        'duration_min':  (times[-1] - times[0]).total_seconds() / 60.0,
    }


def count_crashes(crash_log):
    if not os.path.exists(crash_log):
        return 0
    with open(crash_log, 'r', encoding='utf-8', errors='replace') as f:
        return sum(1 for line in f if line.startswith('===== CRASH'))


def count_kills(folder):
    total = 0
    for p in glob.glob(os.path.join(folder, 'kills_*.log')):
        with open(p, 'r', encoding='utf-8', errors='replace') as f:
            total += sum(1 for line in f if 'killed pid=' in line)
    return total


def analyze_mempool(rows):
    if not rows:
        return {}
    sizes = [v for v in (safe_int(r.get('size')) for r in rows) if v is not None]
    bytes_ = [v for v in (safe_int(r.get('bytes')) for r in rows) if v is not None]
    inj = {}
    for r in rows:
        s = r.get('inject_status', '')
        inj[s] = inj.get(s, 0) + 1
    return {
        'samples':   len(rows),
        'size_max':  max(sizes) if sizes else 0,
        'size_avg':  statistics.fmean(sizes) if sizes else 0,
        'bytes_max': max(bytes_) if bytes_ else 0,
        'inject_breakdown': inj,
    }


def analyze_deploys(rows):
    if not rows:
        return {}
    by_status = {}
    by_method = {}
    for r in rows:
        s = r.get('status', '?')
        m = r.get('method', '?')
        by_status[s] = by_status.get(s, 0) + 1
        by_method[m] = by_method.get(m, 0) + 1
    return {'rows': len(rows), 'by_status': by_status, 'by_method': by_method}


# --------------------------- report formatting ---------------------------

def md_table(headers, rows):
    out = ['| ' + ' | '.join(headers) + ' |',
           '| ' + ' | '.join('---' for _ in headers) + ' |']
    for r in rows:
        out.append('| ' + ' | '.join(str(c) for c in r) + ' |')
    return '\n'.join(out)


def build_report(folder):
    folder = Path(folder)
    parts = [f"# OmniBus Stress Test Report",
             f"",
             f"- Run folder: `{folder}`",
             f"- Generated:  {dt.datetime.now().isoformat(timespec='seconds')}",
             f""]

    # 1) crashes + kills
    crashes = count_crashes(folder / 'crashes.log')
    kills   = count_kills(folder)
    recovery_rate = 'N/A'
    if kills > 0:
        # crashes counts every restart attempt; recovery rate ~= crashes_after_kill / kills
        recovery_rate = f"{min(crashes, kills)}/{kills} ({(min(crashes,kills)/kills*100):.1f}%)"
    parts += ['## Reliability',
              '',
              f'- Crashes recorded: **{crashes}**',
              f'- Chaos kills issued: **{kills}**',
              f'- Recovery (restart-after-kill): **{recovery_rate}**',
              '']

    # 2) RPC + EVM latencies
    rpc_csvs = sorted(glob.glob(str(folder / 'rpc_stress_*.csv')))
    evm_csvs = sorted(glob.glob(str(folder / 'evm_stress_*.csv')))
    conc_csv = sorted(glob.glob(str(folder / 'concurrent_*.csv')))

    def collate(csvs, label):
        all_rows = []
        for c in csvs:
            try:
                all_rows.extend(read_csv(c))
            except Exception:
                pass
        if not all_rows:
            parts.append(f'## {label}\n\n- No CSVs found.\n')
            return
        summary, statuses = analyze_rpc(all_rows)
        rows = [(m, s['count'], f"{s['avg_ms']:.2f}", f"{s['p95_ms']:.2f}",
                 f"{s['p99_ms']:.2f}", f"{s['max_ms']:.2f}") for m, s in summary.items()]
        parts.append(f'## {label}\n')
        parts.append(md_table(['method', 'calls', 'avg_ms', 'p95_ms', 'p99_ms', 'max_ms'], rows))
        parts.append('')
        parts.append('Status breakdown: ' + ', '.join(f'`{k}={v}`' for k, v in statuses.items()))
        parts.append('')

    collate(rpc_csvs, 'RPC Stress')
    collate(evm_csvs, 'EVM Stress')
    collate(conc_csv, 'Concurrent Clients')

    # 3) blocks
    block_csv = folder / 'block_height.csv'
    if block_csv.exists():
        info = analyze_blocks(read_csv(block_csv))
        parts.append('## Block Production')
        parts.append('')
        for k, v in info.items():
            parts.append(f'- **{k}**: {v}')
        parts.append('')

    # 4) metrics
    metrics_csv = folder / 'metrics.csv'
    if metrics_csv.exists():
        info = analyze_metrics(read_csv(metrics_csv))
        parts.append('## Process Metrics (leak detection)')
        parts.append('')
        if info.get('samples'):
            for k, v in info.items():
                parts.append(f'- **{k}**: {v}')
            parts.append('')
            growth = info.get('ram_growth_mb', 0)
            verdict = ('LIKELY LEAK' if growth > 100
                       else 'WATCH'    if growth > 25
                       else 'OK')
            parts.append(f'> Memory growth verdict: **{verdict}** ({growth:+.1f} MB over '
                         f"{info.get('duration_min', 0):.1f} min)")
            parts.append('')
        else:
            parts.append('- No node metric samples.\n')

    # 5) mempool
    mp_csvs = sorted(glob.glob(str(folder / 'mempool_*.csv')))
    if mp_csvs:
        rows = []
        for c in mp_csvs:
            try:
                rows.extend(read_csv(c))
            except Exception:
                pass
        info = analyze_mempool(rows)
        parts.append('## Mempool')
        parts.append('')
        for k, v in info.items():
            parts.append(f'- **{k}**: {v}')
        parts.append('')

    # 6) deploys
    dp_csvs = sorted(glob.glob(str(folder / 'deploys_*.csv')))
    if dp_csvs:
        rows = []
        for c in dp_csvs:
            try:
                rows.extend(read_csv(c))
            except Exception:
                pass
        info = analyze_deploys(rows)
        parts.append('## EVM Deploys')
        parts.append('')
        for k, v in info.items():
            parts.append(f'- **{k}**: {v}')
        parts.append('')

    return '\n'.join(parts)


def to_html(md):
    body = html.escape(md)
    body = re.sub(r'^# (.+)$',  r'<h1>\1</h1>', body, flags=re.M)
    body = re.sub(r'^## (.+)$', r'<h2>\1</h2>', body, flags=re.M)
    body = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', body)
    body = re.sub(r'`([^`]+)`', r'<code>\1</code>', body)
    body = body.replace('\n', '<br/>\n')
    return ("<!doctype html><html><head><meta charset='utf-8'>"
            "<title>OmniBus Stress Report</title>"
            "<style>body{font-family:Segoe UI,Arial,sans-serif;max-width:980px;"
            "margin:24px auto;padding:0 16px;color:#222}h1{color:#0a4}"
            "h2{color:#06c;border-bottom:1px solid #ddd}"
            "code{background:#f4f4f4;padding:1px 4px;border-radius:3px}"
            "</style></head><body>" + body + "</body></html>")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', default=os.path.dirname(os.path.abspath(__file__)),
                    help='Stress test root (default: script dir)')
    ap.add_argument('--date', default=dt.date.today().isoformat(),
                    help='Run date subfolder (default: today)')
    args = ap.parse_args()

    folder = Path(args.root) / args.date
    if not folder.exists():
        print(f'ERROR: {folder} does not exist')
        sys.exit(2)

    md = build_report(folder)
    md_path   = folder / 'REPORT.md'
    html_path = folder / 'REPORT.html'
    md_path.write_text(md, encoding='utf-8')
    html_path.write_text(to_html(md), encoding='utf-8')
    print(f'Wrote {md_path}')
    print(f'Wrote {html_path}')


if __name__ == '__main__':
    main()

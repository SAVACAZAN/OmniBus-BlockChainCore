# OmniBus Stress Test Report

- Run folder: `C:\Kits work\limaje de programare\1_CORE\BlockChainCore\test_results\stress\2026-04-25`
- Generated:  2026-04-25T18:56:07

## Reliability

- Crashes recorded: **79**
- Chaos kills issued: **5**
- Recovery (restart-after-kill): **5/5 (100.0%)**

## RPC Stress

| method | calls | avg_ms | p95_ms | p99_ms | max_ms |
| --- | --- | --- | --- | --- | --- |
| getblockchaininfo | 10828 | 30.53 | 21.40 | 149.64 | 6180.89 |
| eth_chainId | 10685 | 27.93 | 21.83 | 188.62 | 5126.09 |
| getblockcount | 11028 | 28.28 | 21.18 | 146.00 | 5742.03 |
| getbalance | 10859 | 30.87 | 22.93 | 232.50 | 6185.13 |

Status breakdown: `ok=2121`, `http_err:The underlying connection was closed: An unexpected error occurred on a send.=21341`, `http_err:The underlying connection was closed: An unexpected error occurred on a receive.=17733`, `http_err:The underlying connection was closed: The connection was closed unexpectedly.=2111`, `http_err:Unable to connect to the remote server=94`

## EVM Stress

| method | calls | avg_ms | p95_ms | p99_ms | max_ms |
| --- | --- | --- | --- | --- | --- |
| eth_chainId | 4000 | 23.83 | 28.88 | 84.04 | 6181.52 |
| eth_blockNumber | 4000 | 21.47 | 26.25 | 80.24 | 10019.09 |
| eth_gasPrice | 4000 | 29.62 | 23.27 | 128.19 | 5123.49 |
| eth_getCode | 4000 | 33.60 | 12.15 | 507.03 | 4097.82 |
| eth_call | 4000 | 28.29 | 10.21 | 33.17 | 4161.21 |
| eth_estimateGas | 3500 | 24.77 | 8.13 | 21.33 | 4233.82 |

Status breakdown: `ok=5275`, `http_err:The underlying connection was closed: The connection was closed unexpectedly.=853`, `http_err:The underlying connection was closed: An unexpected error occurred on a send.=10684`, `http_err:The underlying connection was closed: An unexpected error occurred on a receive.=6243`, `http_err:Unable to connect to the remote server=46`, `rpc_err:-32601=398`, `http_err:The request was aborted: The operation has timed out.=1`

## Concurrent Clients

| method | calls | avg_ms | p95_ms | p99_ms | max_ms |
| --- | --- | --- | --- | --- | --- |
| getblockchaininfo | 1276 | 64.72 | 47.10 | 2275.06 | 5042.21 |
| eth_gasPrice | 1297 | 74.46 | 45.90 | 3282.05 | 6346.52 |
| eth_chainId | 1168 | 62.29 | 40.48 | 1883.95 | 9230.87 |
| getbalance | 1056 | 57.25 | 33.95 | 1984.95 | 4948.79 |
| getblockcount | 1175 | 61.53 | 44.05 | 2034.44 | 5593.31 |
| eth_blockNumber | 1228 | 76.12 | 50.17 | 3764.03 | 10010.96 |

Status breakdown: `http_err=7008`, `ok=123`, `rpc_err:-32601=69`

## Block Production

- **samples**: 175
- **first_height**: 1
- **last_height**: 1
- **delta**: 0
- **duration_min**: 16.63261363333333
- **blocks_per_min**: 0.0
- **blocks_per_hour**: 0.0
- **stall_ticks**: 170

## Process Metrics (leak detection)

- **samples**: 108
- **ram_first_mb**: 14.73
- **ram_last_mb**: 14.8
- **ram_max_mb**: 25.77
- **ram_growth_mb**: 0.07000000000000028
- **cpu_total_sec**: 1.312
- **handles_max**: 117
- **threads_max**: 13
- **disk_first_mb**: 0.0
- **disk_last_mb**: 0.0
- **duration_min**: 16.5935275

> Memory growth verdict: **OK** (+0.1 MB over 16.6 min)

## Mempool

- **samples**: 2294
- **size_max**: 0
- **size_avg**: 0.0
- **bytes_max**: 0
- **inject_breakdown**: {'rpc_err:-32601': 303, 'skipped': 1835, 'unsupported_or_err': 156}

## EVM Deploys

- **rows**: 1600
- **by_status**: {'http_err': 1070, 'rpc_err:-32602': 263, 'rpc_err:-32601': 267}
- **by_method**: {'eth_estimateGas': 800, 'eth_sendTransaction': 800}

În repo C:\Kits work\limaje de programare\1_CORE\BlockChainCore, `zig build test` falie
la aggregation chiar dacă toate modulele individual pass (vezi MEMORY.md
test_status_2026_05_11). Citește build.zig, identifică parser issue în secțiunea care
agregă test steps (test, test-crypto, test-chain, test-net, test-shard, test-storage,
test-light, test-pq, test-wallet), fix root cause. Verifică cu `zig build test-crypto`
și `zig build test-chain`. Estimat: 15-30 min.
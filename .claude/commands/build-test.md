# /build-test

Build the OmniBus blockchain node and run all tests.

## Steps

1. `zig build`
2. `zig build test-crypto`
3. `zig build test-chain`
4. `zig build test-net`
5. `zig build test-storage`
6. `zig build test-pq`
7. `zig build test-light`
8. `zig build test-shard`

Or simply run the master test runner:
```bash
bash scripts/testing/run-all-tests.sh
```

## Output

- Binaries in `zig-out/bin/`
- Test results in console

# 1. Verifică fiecare modul individual
zig build test-core
zig build test-crypto
zig build test-net
zig build test-pq

# 2. Rulează toate testele
zig build test

# 3. Dacă sunt erori de compilare, fixează importurile lipsă
# (majoritatea modulelor au nevoie de importul corect al dependențelor)
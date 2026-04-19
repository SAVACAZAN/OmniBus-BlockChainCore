// heap_overflow_exploit.cpp
// Heap overflow în CTransaction deserialization
// Target: Bitcoin Core < 22.0
#include <primitives/transaction.h>
#include <serialize.h>

class HeapOverflowExploit {
// consensus_fuzz.cpp
// libFuzzer entry point for consensus validation
#include <consensus/validation.h>
#include <primitives/block.h>
#include <serialize.h>
#include <stdint.h>
#include <vector>
#include "../../include/omnibus/consensus/pow.hpp"
#include "../../include/omnibus/consensus/params.hpp"
#include <cmath>

namespace omnibus::consensus {

// Additional PoW helper implementations
bool is_valid_pow(const BlockHeader& header) {
    Hash256 hash = header.hash();
    return check_pow(hash, header.bits);
}

u32 calculate_next_difficulty(const BlockHeader& prev_header, u32 actual_timespan_sec) {
    return retarget_difficulty(prev_header.bits, actual_timespan_sec);
}

} // namespace omnibus::consensus
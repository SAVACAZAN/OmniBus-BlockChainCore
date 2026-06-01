cmake_minimum_required(VERSION 3.24)
project(omnibus-node-cpp VERSION 1.0.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

include(FetchContent)

# ── Options ─────────────────────────────────────────────────────────────────
option(BUILD_TESTS "Build unit tests (Catch2)" ON)
option(USE_OPENSSL "Use OpenSSL for SHA256/RIPEMD/HMAC/RAND" ON)

# Paths for locally-compiled libraries (no pkg-config needed on Windows).
set(OMNIBUS_LIBOQS_INCLUDE "" CACHE PATH "liboqs include dir (contains oqs/oqs.h)")
set(OMNIBUS_LIBOQS_LIB     "" CACHE FILEPATH "liboqs static lib (liboqs.a)")
set(OMNIBUS_SECP256K1_INCLUDE "" CACHE PATH "secp256k1 include dir (contains secp256k1.h)")
set(OMNIBUS_SECP256K1_LIB     "" CACHE FILEPATH "secp256k1 static lib (libsecp256k1.a)")

# Auto-detect from sibling ecosystem paths if not set.
if(NOT OMNIBUS_LIBOQS_INCLUDE)
    set(OMNIBUS_LIBOQS_INCLUDE "${CMAKE_CURRENT_SOURCE_DIR}/../../liboqs-src/build/include")
endif()
if(NOT OMNIBUS_LIBOQS_LIB)
    set(OMNIBUS_LIBOQS_LIB "${CMAKE_CURRENT_SOURCE_DIR}/../../liboqs-src/build/lib/liboqs.a")
endif()
if(NOT OMNIBUS_SECP256K1_INCLUDE)
    set(OMNIBUS_SECP256K1_INCLUDE "${CMAKE_CURRENT_SOURCE_DIR}/../../refs/bitcoin/src/secp256k1/include")
endif()
if(NOT OMNIBUS_SECP256K1_LIB)
    # Reuse secp256k1 static lib built by the Rust sibling's secp256k1-sys crate.
    file(GLOB _SECP_CANDIDATES
        "${CMAKE_CURRENT_SOURCE_DIR}/../core-rust/target/debug/build/secp256k1-sys-*/out/libsecp256k1.a"
        "${CMAKE_CURRENT_SOURCE_DIR}/../core-rust/target/release/build/secp256k1-sys-*/out/libsecp256k1.a"
    )
    if(_SECP_CANDIDATES)
        list(GET _SECP_CANDIDATES 0 OMNIBUS_SECP256K1_LIB)
    endif()
endif()

message(STATUS "liboqs include: ${OMNIBUS_LIBOQS_INCLUDE}")
message(STATUS "liboqs lib:     ${OMNIBUS_LIBOQS_LIB}")
message(STATUS "secp256k1 include: ${OMNIBUS_SECP256K1_INCLUDE}")
message(STATUS "secp256k1 lib:     ${OMNIBUS_SECP256K1_LIB}")

# ── FetchContent deps (header-only or small) ─────────────────────────────────
FetchContent_Declare(nlohmann_json
    GIT_REPOSITORY https://github.com/nlohmann/json.git
    GIT_TAG v3.11.3
    GIT_SHALLOW TRUE
)
FetchContent_MakeAvailable(nlohmann_json)

FetchContent_Declare(spdlog
    GIT_REPOSITORY https://github.com/gabime/spdlog.git
    GIT_TAG v1.14.1
    GIT_SHALLOW TRUE
)
FetchContent_MakeAvailable(spdlog)

# Standalone Boost.Asio (no full Boost install required) + Beast headers.
FetchContent_Declare(asio
    GIT_REPOSITORY https://github.com/chriskohlhoff/asio.git
    GIT_TAG asio-1-30-2
    GIT_SHALLOW TRUE
)
FetchContent_MakeAvailable(asio)

FetchContent_Declare(boost_beast
    GIT_REPOSITORY https://github.com/boostorg/beast.git
    GIT_TAG boost-1.84.0
    GIT_SHALLOW TRUE
)
FetchContent_MakeAvailable(boost_beast)

if(BUILD_TESTS)
    FetchContent_Declare(Catch2
        GIT_REPOSITORY https://github.com/catchorg/Catch2.git
        GIT_TAG v3.6.0
        GIT_SHALLOW TRUE
    )
    FetchContent_MakeAvailable(Catch2)
    enable_testing()
    include(CTest)
endif()

# libsodium shim — wrap with OpenSSL if available, otherwise a minimal impl.
if(USE_OPENSSL)
    find_package(OpenSSL REQUIRED)
endif()

# ── Interface targets for local libs ─────────────────────────────────────────
add_library(omnibus_liboqs STATIC IMPORTED)
set_target_properties(omnibus_liboqs PROPERTIES
    IMPORTED_LOCATION "${OMNIBUS_LIBOQS_LIB}"
    INTERFACE_INCLUDE_DIRECTORIES "${OMNIBUS_LIBOQS_INCLUDE}"
)

add_library(omnibus_secp256k1 STATIC IMPORTED)
set_target_properties(omnibus_secp256k1 PROPERTIES
    IMPORTED_LOCATION "${OMNIBUS_SECP256K1_LIB}"
    INTERFACE_INCLUDE_DIRECTORIES "${OMNIBUS_SECP256K1_INCLUDE}"
)

# Standalone Asio (header-only, no Boost headers needed).
add_library(standalone_asio INTERFACE)
target_include_directories(standalone_asio INTERFACE
    ${asio_SOURCE_DIR}/asio/include
    ${boost_beast_SOURCE_DIR}/include
)
target_compile_definitions(standalone_asio INTERFACE ASIO_STANDALONE)

# ── Library (all protocol code) ─────────────────────────────────────────────
set(LIB_SOURCES
    src/agents/executor.cpp
    src/agents/manager.cpp
    src/consensus/block.cpp
    src/consensus/finality.cpp
    src/consensus/genesis.cpp
    src/consensus/mempool.cpp
    src/consensus/pow.cpp
    src/consensus/sub_block.cpp
    src/crypto/bech32.cpp
    src/crypto/bip32.cpp
    src/crypto/keccak.cpp
    src/crypto/pq.cpp
    src/crypto/ripemd160.cpp
    src/crypto/secp256k1.cpp
    src/crypto/sha256.cpp
    src/dex/grid.cpp
    src/dex/htlc.cpp
    src/dex/matching.cpp
    src/dex/oracle.cpp
    src/dns.cpp
    src/governance/proposal.cpp
    src/guardian.cpp
    src/identity/did.cpp
    src/identity/kyc.cpp
    src/identity/manifest.cpp
    src/identity/mica.cpp
    src/identity/ns.cpp
    src/identity/salt.cpp
    src/light/bloom.cpp
    src/light/client.cpp
    src/light/spv.cpp
    src/mining/engine.cpp
    src/mining/pool.cpp
    src/mining/stratum.cpp
    src/p2p/bootstrap.cpp
    src/p2p/node.cpp
    src/p2p/peer.cpp
    src/p2p/scoring.cpp
    src/p2p/sync.cpp
    src/p2p/wire.cpp
    src/rpc/eth.cpp
    src/rpc/native.cpp
    src/rpc/server.cpp
    src/shard/coordinator.cpp
    src/shard/metachain.cpp
    src/storage/chain_db.cpp
    src/storage/compact_tx.cpp
    src/storage/state_trie.cpp
    src/validator/set.cpp
    src/validator/slashing.cpp
    src/validator/staking.cpp
    src/vault.cpp
    src/wallet/address.cpp
    src/wallet/hd.cpp
    src/ws/server.cpp
)

add_library(omnibus_node_lib STATIC ${LIB_SOURCES})
target_include_directories(omnibus_node_lib PUBLIC include)
target_link_libraries(omnibus_node_lib
    PUBLIC
        omnibus_liboqs
        omnibus_secp256k1
        standalone_asio
        nlohmann_json::nlohmann_json
        spdlog::spdlog
        Threads::Threads
)
if(USE_OPENSSL)
    target_link_libraries(omnibus_node_lib PUBLIC OpenSSL::Crypto)
    target_compile_definitions(omnibus_node_lib PUBLIC USE_OPENSSL OMNIBUS_SODIUM_VIA_OPENSSL)
endif()
if(WIN32)
    target_link_libraries(omnibus_node_lib PUBLIC ws2_32 mswsock)
endif()
target_compile_options(omnibus_node_lib PRIVATE
    $<$<CXX_COMPILER_ID:GNU>:-Wall -Wextra -Wno-unused-parameter>
    $<$<CXX_COMPILER_ID:MSVC>:/W3>
)

find_package(Threads REQUIRED)

# ── Executables ─────────────────────────────────────────────────────────────
add_executable(omnibus-node apps/omnibus-node.cpp)
target_link_libraries(omnibus-node PRIVATE omnibus_node_lib)

add_executable(omnibus-cli apps/omnibus-cli.cpp)
target_link_libraries(omnibus-cli PRIVATE omnibus_node_lib)

# ── Tests ────────────────────────────────────────────────────────────────────
if(BUILD_TESTS)
    include(${Catch2_SOURCE_DIR}/extras/Catch.cmake)
    set(TEST_SOURCES
        tests/test_vectors.cpp
        tests/test_crypto.cpp
        tests/test_consensus.cpp
        tests/test_dex.cpp
        tests/test_identity.cpp
        tests/test_wallet.cpp
        tests/test_validation.cpp
        tests/test_p2p.cpp
    )
    add_executable(omnibus-tests ${TEST_SOURCES})
    target_link_libraries(omnibus-tests PRIVATE omnibus_node_lib Catch2::Catch2WithMain)
    catch_discover_tests(omnibus-tests)
endif()

# ── Install ──────────────────────────────────────────────────────────────────
install(TARGETS omnibus-node omnibus-cli RUNTIME DESTINATION bin)

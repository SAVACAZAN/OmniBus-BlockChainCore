// OEP-1 141/150 | path=CMakeLists.txt (updated with all components) | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
# OEP-1 141/150 | path=CMakeLists.txt | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
cmake_minimum_required(VERSION 3.20)
project(omnibus-node-cpp VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Options
option(BUILD_TESTS "Build unit tests" ON)
option(BUILD_CLI "Build CLI tool" ON)
option(USE_OPENSSL "Use OpenSSL for crypto" ON)
option(USE_LIBSODIUM "Use libsodium as fallback" OFF)

# Dependencies
find_package(PkgConfig REQUIRED)
pkg_check_modules(LIBSECP256K1 REQUIRED libsecp256k1)
pkg_check_modules(LIBOQS REQUIRED liboqs)
find_package(Boost REQUIRED COMPONENTS system asio)
find_package(nlohmann_json REQUIRED)
find_package(spdlog REQUIRED)
find_package(Threads REQUIRED)
find_package(ZLIB REQUIRED)

if(USE_OPENSSL)
    find_package(OpenSSL REQUIRED)
    target_compile_definitions(omnibus_lib PRIVATE USE_OPENSSL)
endif()

if(BUILD_TESTS)
    find_package(Catch2 REQUIRED)
    enable_testing()
endif()

# Main library (header-only + compiled sources)
add_library(omnibus_lib STATIC
    src/crypto/sha256.cpp
    src/crypto/keccak.cpp
    src/crypto/ripemd160.cpp
    src/crypto/secp256k1.cpp
    src/crypto/bech32.cpp
    src/crypto/bip32.cpp
    src/crypto/pq.cpp
    src/wallet/hd.cpp
    src/wallet/address.cpp
    src/consensus/block.cpp
    src/consensus/sub_block.cpp
    src/consensus/genesis.cpp
    src/consensus/pow.cpp
    src/consensus/finality.cpp
    src/consensus/mempool.cpp
    src/storage/chain_db.cpp
    src/storage/state_trie.cpp
    src/storage/compact_tx.cpp
    src/p2p/wire.cpp
    src/p2p/peer.cpp
    src/p2p/node.cpp
    src/p2p/scoring.cpp
    src/p2p/sync.cpp
    src/p2p/bootstrap.cpp
    src/dex/matching.cpp
    src/dex/htlc.cpp
    src/dex/grid.cpp
    src/dex/oracle.cpp
    src/identity/did.cpp
    src/identity/manifest.cpp
    src/identity/salt.cpp
    src/identity/kyc.cpp
    src/identity/mica.cpp
    src/identity/ns.cpp
    src/governance/proposal.cpp
    src/validator/staking.cpp
    src/validator/set.cpp
    src/validator/slashing.cpp
    src/mining/engine.cpp
    src/mining/pool.cpp
    src/mining/stratum.cpp
    src/light/spv.cpp
    src/light/bloom.cpp
    src/light/client.cpp
    src/rpc/server.cpp
    src/rpc/eth.cpp
    src/rpc/native.cpp
    src/ws/server.cpp
    src/shard/coordinator.cpp
    src/shard/metachain.cpp
    src/agents/executor.cpp
    src/agents/manager.cpp
    src/vault.cpp
    src/guardian.cpp
    src/dns.cpp
)

target_include_directories(omnibus_lib PUBLIC include)
target_link_libraries(omnibus_lib
    PUBLIC
    ${LIBSECP256K1_LIBRARIES}
    ${LIBOQS_LIBRARIES}
    Boost::system
    Boost::asio
    nlohmann_json::nlohmann_json
    spdlog::spdlog
    Threads::Threads
    ZLIB::ZLIB
)
if(USE_OPENSSL)
    target_link_libraries(omnibus_lib PUBLIC OpenSSL::Crypto)
endif()

target_compile_options(omnibus_lib PRIVATE -Wall -Wextra -Wpedantic)

# Main node executable
add_executable(omnibus-node apps/omnibus-node.cpp)
target_link_libraries(omnibus-node PRIVATE omnibus_lib)

# CLI tool
if(BUILD_CLI)
    add_executable(omnibus-cli apps/omnibus-cli.cpp)
    target_link_libraries(omnibus-cli PRIVATE omnibus_lib)
endif()

# Tests
if(BUILD_TESTS)
    add_executable(omnibus-tests
        tests/test_vectors.cpp
        tests/test_crypto.cpp
        tests/test_consensus.cpp
        tests/test_dex.cpp
        tests/test_identity.cpp
        tests/test_wallet.cpp
        tests/test_validation.cpp
        tests/test_p2p.cpp
    )
    target_link_libraries(omnibus-tests PRIVATE Catch2::Catch2 omnibus_lib)
    include(CTest)
    include(Catch)
    catch_discover_tests(omnibus-tests)
endif()

# Installation
install(TARGETS omnibus-node omnibus_lib
    RUNTIME DESTINATION bin
    LIBRARY DESTINATION lib
    ARCHIVE DESTINATION lib
)
if(BUILD_CLI)
    install(TARGETS omnibus-cli RUNTIME DESTINATION bin)
endif()

# CPack for packaging
set(CPACK_PACKAGE_NAME "omnibus-node-cpp")
set(CPACK_PACKAGE_VERSION "1.0.0")
set(CPACK_PACKAGE_DESCRIPTION "OmniBus blockchain C++ implementation")
include(CPack)
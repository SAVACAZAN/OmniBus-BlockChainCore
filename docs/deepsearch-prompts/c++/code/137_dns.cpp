// OEP-1 133/150 | path=apps/omnibus-node.cpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#include <iostream>
#include <string>
#include <getopt.h>
#include <spdlog/spdlog.h>
#include <spdlog/sinks/stdout_color_sinks.h>
#include "../include/omnibus/p2p/node.hpp"
#include "../include/omnibus/p2p/bootstrap.hpp"
#include "../include/omnibus/mining/engine.hpp"
#include "../include/omnibus/consensus/mempool.hpp"
#include "../include/omnibus/rpc/server.hpp"
#include "../include/omnibus/rpc/native.hpp"
#include "../include/omnibus/rpc/eth.hpp"
#include "../include/omnibus/ws/server.hpp"

using namespace omnibus;

struct Config {
    std::string mode = "seed"; // seed, miner, evm
    Network network = Network::Mainnet;
    u16 p2p_port = 9000;
    u16 rpc_port = 8332;
    u16 ws_port = 8334;
    u16 evm_port = 8333;
    std::string seed_host = "127.0.0.1";
    u16 seed_port = 9000;
    std::string data_dir = "./data";
    bool verbose = false;
};

static void print_usage(const char* prog) {
    std::cout << "Usage: " << prog << " [options]\n"
              << "Options:\n"
              << "  --mode <seed|miner|evm>     Node mode (default: seed)\n"
              << "  --network <mainnet|testnet|devnet|regtest> (default: mainnet)\n"
              << "  --p2p-port <port>           P2P port (default: 9000)\n"
              << "  --rpc-port <port>           RPC port (default: 8332)\n"
              << "  --ws-port <port>            WebSocket port (default: 8334)\n"
              << "  --evm-port <port>           EVM JSON-RPC port (default: 8333)\n"
              << "  --seed-host <host>          Seed node host (default: 127.0.0.1)\n"
              << "  --seed-port <port>          Seed node port (default: 9000)\n"
              << "  --data-dir <path>           Data directory (default: ./data)\n"
              << "  --verbose                   Enable verbose logging\n"
              << "  -h, --help                  Show this help\n";
}

static Network parse_network(const std::string& str) {
    if (str == "mainnet") return Network::Mainnet;
    if (str == "testnet") return Network::Testnet;
    if (str == "devnet") return Network::Devnet;
    if (str == "regtest") return Network::Regtest;
    return Network::Mainnet;
}

int main(int argc, char* argv[]) {
    Config config;
    
    static option long_options[] = {
        {"mode", required_argument, 0, 0},
        {"network", required_argument, 0, 0},
        {"p2p-port", required_argument, 0, 0},
        {"rpc-port", required_argument, 0, 0},
        {"ws-port", required_argument, 0, 0},
        {"evm-port", required_argument, 0, 0},
        {"seed-host", required_argument, 0, 0},
        {"seed-port", required_argument, 0, 0},
        {"data-dir", required_argument, 0, 0},
        {"verbose", no_argument, 0, 'v'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };
    
    int opt;
    int option_index = 0;
    while ((opt = getopt_long(argc, argv, "vh", long_options, &option_index)) != -1) {
        switch (opt) {
            case 0:
                if (std::string(long_options[option_index].name) == "mode") {
                    config.mode = optarg;
                } else if (std::string(long_options[option_index].name) == "network") {
                    config.network = parse_network(optarg);
                } else if (std::string(long_options[option_index].name) == "p2p-port") {
                    config.p2p_port = static_cast<u16>(std::stoi(optarg));
                } else if (std::string(long_options[option_index].name) == "rpc-port") {
                    config.rpc_port = static_cast<u16>(std::stoi(optarg));
                } else if (std::string(long_options[option_index].name) == "ws-port") {
                    config.ws_port = static_cast<u16>(std::stoi(optarg));
                } else if (std::string(long_options[option_index].name) == "evm-port") {
                    config.evm_port = static_cast<u16>(std::stoi(optarg));
                } else if (std::string(long_options[option_index].name) == "seed-host") {
                    config.seed_host = optarg;
                } else if (std::string(long_options[option_index].name) == "seed-port") {
                    config.seed_port = static_cast<u16>(std::stoi(optarg));
                } else if (std::string(long_options[option_index].name) == "data-dir") {
                    config.data_dir = optarg;
                }
                break;
            case 'v':
                config.verbose = true;
                break;
            case 'h':
                print_usage(argv[0]);
                return 0;
            default:
                print_usage(argv[0]);
                return 1;
        }
    }
    
    // Setup logging
    auto console_sink = std::make_shared<spdlog::sinks::stdout_color_sink_mt>();
    if (config.verbose) {
        spdlog::set_level(spdlog::level::debug);
    } else {
        spdlog::set_level(spdlog::level::info);
    }
    spdlog::set_default_logger(std::make_shared<spdlog::logger>("omnibus", console_sink));
    
    spdlog::info("OmniBus C++ Node starting in {} mode", config.mode);
    spdlog::info("Network: {}", static_cast<int>(config.network));
    
    // Create components
    auto mempool = std::make_shared<consensus::Mempool>();
    auto p2p_node = std::make_shared<p2p::P2PNode>(config.network, config.p2p_port);
    auto rpc_server = std::make_unique<rpc::RPCServer>(config.rpc_port);
    auto ws_server = std::make_shared<ws::WebSocketServer>(config.ws_port, p2p_node->io_context());
    
    // Register RPC methods
    rpc::native::register_native_methods(*rpc_server);
    rpc::eth::register_eth_methods(*rpc_server);
    
    // Start P2P
    p2p_node->start();
    
    // Connect to seed if not in seed mode
    if (config.mode != "seed") {
        p2p_node->add_seed(config.seed_host, config.seed_port);
    }
    
    // Start mining if in miner mode
    std::unique_ptr<mining::MiningEngine> mining_engine;
    if (config.mode == "miner") {
        Hash160 dummy_coinbase{};
        mining_engine = std::make_unique<mining::MiningEngine>(
            config.network, mempool, p2p_node, dummy_coinbase);
        mining_engine->start();
    }
    
    // Start RPC server
    std::thread rpc_thread([&rpc_server]() {
        rpc_server->start();
        rpc_server->run();
    });
    
    // Start WebSocket server
    ws_server->start();
    
    // Run P2P (blocking)
    p2p_node->run();
    
    // Cleanup
    rpc_server->stop();
    if (mining_engine) mining_engine->stop();
    rpc_thread.join();
    
    return 0;
}
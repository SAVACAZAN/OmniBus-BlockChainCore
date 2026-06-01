#include <iostream>
#include <string>
#include "../include/omnibus/wallet/hd.hpp"
#include "../include/omnibus/wallet/address.hpp"
#include "../include/omnibus/crypto/bip32.hpp"

int main(int argc, char* argv[]) {
    if (argc < 2) {
        std::cerr << "Usage: omnibus-cli <command> [args]\n";
        return 1;
    }
    std::string cmd = argv[1];
    if (cmd == "genesis-hash") {
        std::cout << "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982\n";
    } else if (cmd == "new-address") {
        // Simple mnemonic generation (dummy)
        std::cout << "ob1qxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n";
    } else {
        std::cerr << "Unknown command\n";
        return 1;
    }
    return 0;
}
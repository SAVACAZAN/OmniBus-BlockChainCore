// OEP-1 99/150 | path=include/omnibus/vault.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
#pragma once
#include "types.hpp"
#include <string>
#include <optional>
#include <vector>

namespace omnibus {

// Secure vault for private keys (IPC)
class Vault {
public:
#ifdef _WIN32
    static constexpr const char* PIPE_NAME = "\\\\.\\pipe\\OmnibusVault";
#else
    static constexpr const char* SOCKET_PATH = "/var/run/omnibus/vault.sock";
#endif

    struct KeyEntry {
        std::string name;
        std::vector<u8> public_key;
        std::vector<u8> encrypted_private_key;
        u64 created_at;
    };
    
    static bool store_key(const std::string& name, const std::vector<u8>& private_key, const std::string& passphrase);
    static std::optional<std::vector<u8>> retrieve_key(const std::string& name, const std::string& passphrase);
    static bool delete_key(const std::string& name);
    static std::vector<KeyEntry> list_keys();
    static bool change_passphrase(const std::string& name, const std::string& old_pass, const std::string& new_pass);
    
private:
    static std::string get_vault_path();
    static std::vector<u8> encrypt(const std::vector<u8>& data, const std::string& passphrase);
    static std::optional<std::vector<u8>> decrypt(const std::vector<u8>& encrypted, const std::string& passphrase);
};

} // namespace omnibus
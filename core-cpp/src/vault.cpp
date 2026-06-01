#include "../include/omnibus/vault.hpp"
#include "../include/omnibus/crypto/sha256.hpp"
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <fstream>
#include <filesystem>
#include <spdlog/spdlog.h>

namespace omnibus {

std::string Vault::get_vault_path() {
#ifdef _WIN32
    return std::string(getenv("APPDATA")) + "\\Omnibus\\vault.dat";
#else
    return std::string(getenv("HOME")) + "/.omnibus/vault.dat";
#endif
}

std::vector<u8> Vault::encrypt(const std::vector<u8>& data, const std::string& passphrase) {
    // Derive key from passphrase using PBKDF2
    std::vector<u8> salt(16);
    RAND_bytes(salt.data(), 16);
    
    std::vector<u8> key(32);
    PKCS5_PBKDF2_HMAC(passphrase.c_str(), passphrase.size(),
                      salt.data(), salt.size(),
                      100000, EVP_sha256(), 32, key.data());
    
    // AES-256-GCM encryption
    std::vector<u8> iv(12);
    RAND_bytes(iv.data(), 12);
    
    EVP_CIPHER_CTX* ctx = EVP_CIPHER_CTX_new();
    EVP_EncryptInit_ex(ctx, EVP_aes_256_gcm(), nullptr, key.data(), iv.data());
    
    std::vector<u8> ciphertext(data.size() + 16);
    int len;
    EVP_EncryptUpdate(ctx, ciphertext.data(), &len, data.data(), data.size());
    int ciphertext_len = len;
    EVP_EncryptFinal_ex(ctx, ciphertext.data() + len, &len);
    ciphertext_len += len;
    
    std::vector<u8> tag(16);
    EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, 16, tag.data());
    EVP_CIPHER_CTX_free(ctx);
    
    ciphertext.resize(ciphertext_len);
    
    // Format: salt(16) + iv(12) + tag(16) + ciphertext
    std::vector<u8> result;
    result.insert(result.end(), salt.begin(), salt.end());
    result.insert(result.end(), iv.begin(), iv.end());
    result.insert(result.end(), tag.begin(), tag.end());
    result.insert(result.end(), ciphertext.begin(), ciphertext.end());
    
    return result;
}

std::optional<std::vector<u8>> Vault::decrypt(const std::vector<u8>& encrypted, const std::string& passphrase) {
    if (encrypted.size() < 44) return std::nullopt; // 16+12+16
    
    std::vector<u8> salt(encrypted.begin(), encrypted.begin() + 16);
    std::vector<u8> iv(encrypted.begin() + 16, encrypted.begin() + 28);
    std::vector<u8> tag(encrypted.begin() + 28, encrypted.begin() + 44);
    std::vector<u8> ciphertext(encrypted.begin() + 44, encrypted.end());
    
    std::vector<u8> key(32);
    PKCS5_PBKDF2_HMAC(passphrase.c_str(), passphrase.size(),
                      salt.data(), salt.size(),
                      100000, EVP_sha256(), 32, key.data());
    
    EVP_CIPHER_CTX* ctx = EVP_CIPHER_CTX_new();
    EVP_DecryptInit_ex(ctx, EVP_aes_256_gcm(), nullptr, key.data(), iv.data());
    EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, 16, tag.data());
    
    std::vector<u8> plaintext(ciphertext.size());
    int len;
    EVP_DecryptUpdate(ctx, plaintext.data(), &len, ciphertext.data(), ciphertext.size());
    int plaintext_len = len;
    
    int ret = EVP_DecryptFinal_ex(ctx, plaintext.data() + len, &len);
    EVP_CIPHER_CTX_free(ctx);
    
    if (ret <= 0) return std::nullopt;
    
    plaintext_len += len;
    plaintext.resize(plaintext_len);
    return plaintext;
}

bool Vault::store_key(const std::string& name, const std::vector<u8>& private_key, const std::string& passphrase) {
    auto encrypted = encrypt(private_key, passphrase);
    
    std::filesystem::create_directories(std::filesystem::path(get_vault_path()).parent_path());
    
    std::ofstream file(get_vault_path(), std::ios::binary | std::ios::app);
    if (!file.is_open()) return false;
    
    // Write key entry: name_len (4 bytes) + name + key_len (4 bytes) + encrypted_key
    u32 name_len = name.size();
    file.write(reinterpret_cast<const char*>(&name_len), 4);
    file.write(name.c_str(), name_len);
    u32 key_len = encrypted.size();
    file.write(reinterpret_cast<const char*>(&key_len), 4);
    file.write(reinterpret_cast<const char*>(encrypted.data()), key_len);
    
    spdlog::info("Stored key: {}", name);
    return true;
}

std::optional<std::vector<u8>> Vault::retrieve_key(const std::string& name, const std::string& passphrase) {
    std::ifstream file(get_vault_path(), std::ios::binary);
    if (!file.is_open()) return std::nullopt;
    
    while (file.peek() != EOF) {
        u32 name_len;
        file.read(reinterpret_cast<char*>(&name_len), 4);
        if (file.eof()) break;
        
        std::string entry_name(name_len, '\0');
        file.read(entry_name.data(), name_len);
        
        u32 key_len;
        file.read(reinterpret_cast<char*>(&key_len), 4);
        
        std::vector<u8> encrypted(key_len);
        file.read(reinterpret_cast<char*>(encrypted.data()), key_len);
        
        if (entry_name == name) {
            return decrypt(encrypted, passphrase);
        }
    }
    
    return std::nullopt;
}

bool Vault::delete_key(const std::string& name) {
    std::ifstream infile(get_vault_path(), std::ios::binary);
    if (!infile.is_open()) return false;
    
    std::vector<u8> new_content;
    bool found = false;
    
    while (infile.peek() != EOF) {
        u32 name_len;
        infile.read(reinterpret_cast<char*>(&name_len), 4);
        if (infile.eof()) break;
        
        std::string entry_name(name_len, '\0');
        infile.read(entry_name.data(), name_len);
        
        u32 key_len;
        infile.read(reinterpret_cast<char*>(&key_len), 4);
        
        std::vector<u8> encrypted(key_len);
        infile.read(reinterpret_cast<char*>(encrypted.data()), key_len);
        
        if (entry_name != name) {
            // Keep this entry
            new_content.insert(new_content.end(), reinterpret_cast<u8*>(&name_len), reinterpret_cast<u8*>(&name_len) + 4);
            new_content.insert(new_content.end(), entry_name.begin(), entry_name.end());
            new_content.insert(new_content.end(), reinterpret_cast<u8*>(&key_len), reinterpret_cast<u8*>(&key_len) + 4);
            new_content.insert(new_content.end(), encrypted.begin(), encrypted.end());
        } else {
            found = true;
        }
    }
    
    infile.close();
    
    if (found) {
        std::ofstream outfile(get_vault_path(), std::ios::binary | std::ios::trunc);
        outfile.write(reinterpret_cast<const char*>(new_content.data()), new_content.size());
        spdlog::info("Deleted key: {}", name);
        return true;
    }
    
    return false;
}

std::vector<Vault::KeyEntry> Vault::list_keys() {
    std::vector<KeyEntry> entries;
    std::ifstream file(get_vault_path(), std::ios::binary);
    if (!file.is_open()) return entries;
    
    while (file.peek() != EOF) {
        u32 name_len;
        file.read(reinterpret_cast<char*>(&name_len), 4);
        if (file.eof()) break;
        
        KeyEntry entry;
        entry.name.resize(name_len);
        file.read(entry.name.data(), name_len);
        
        u32 key_len;
        file.read(reinterpret_cast<char*>(&key_len), 4);
        
        entry.encrypted_private_key.resize(key_len);
        file.read(reinterpret_cast<char*>(entry.encrypted_private_key.data()), key_len);
        entry.created_at = 0; // Not stored in this simple format
        
        entries.push_back(entry);
    }
    
    return entries;
}

bool Vault::change_passphrase(const std::string& name, const std::string& old_pass, const std::string& new_pass) {
    auto privkey = retrieve_key(name, old_pass);
    if (!privkey) return false;
    
    delete_key(name);
    return store_key(name, *privkey, new_pass);
}

} // namespace omnibus
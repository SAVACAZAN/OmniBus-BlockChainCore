#pragma once

#include <QByteArray>
#include <QString>
#include <QStringList>
#include <array>
#include <cstdint>
#include <vector>

namespace omni {
namespace crypto {

// ─── SHA-256 ───
QByteArray sha256(const QByteArray& data);
QByteArray doubleSha256(const QByteArray& data);

// ─── HMAC-SHA512 ───
QByteArray hmacSha512(const QByteArray& key, const QByteArray& data);

// ─── SHA-512 ───
QByteArray sha512(const QByteArray& data);

// ─── RIPEMD-160 ───
QByteArray ripemd160(const QByteArray& data);

// ─── Hash160 = RIPEMD160(SHA256(data)) ───
QByteArray hash160(const QByteArray& data);

// ─── PBKDF2-HMAC-SHA512 ───
QByteArray pbkdf2HmacSha512(const QByteArray& password, const QByteArray& salt, int iterations, int keyLen = 64);

// ─── AES-256-CBC ───
QByteArray aes256Encrypt(const QByteArray& plaintext, const QByteArray& key, const QByteArray& iv);
QByteArray aes256Decrypt(const QByteArray& ciphertext, const QByteArray& key, const QByteArray& iv);

// ─── Random ───
QByteArray randomBytes(int count);

// ─── BIP-39 Mnemonic ───
QStringList bip39Wordlist();       // returns the 2048 English words
QString generateMnemonic(int wordCount = 12); // 12 or 24 words
QByteArray mnemonicToSeed(const QString& mnemonic, const QString& passphrase = "");
bool validateMnemonic(const QString& mnemonic);

// ─── BIP-32 HD Key Derivation ───
struct ExtendedKey {
    QByteArray key;       // 32 bytes private key (or 33 bytes compressed pubkey)
    QByteArray chainCode; // 32 bytes
    uint32_t depth = 0;
    uint32_t childIndex = 0;
    QByteArray parentFingerprint; // 4 bytes
};

ExtendedKey masterKeyFromSeed(const QByteArray& seed);
ExtendedKey deriveChild(const ExtendedKey& parent, uint32_t index); // index | 0x80000000 for hardened
ExtendedKey derivePath(const ExtendedKey& master, const QString& path); // e.g. "m/44'/9999'/0'/0/0"

// ─── secp256k1 public key from private key ───
QByteArray privateToPublicKey(const QByteArray& privKey); // returns 33-byte compressed pubkey
QByteArray privateToUncompressedPublicKey(const QByteArray& privKey); // 65-byte uncompressed

// ─── Bech32 address encoding ───
QString pubkeyToOb1qAddress(const QByteArray& compressedPubkey); // Hash160 -> Bech32 with "ob1q" prefix
QString pubkeyHashToAddress(const QByteArray& hash20, const QString& hrp = "ob"); // raw hash160 -> bech32

// ─── ECDSA signing (for transaction signing) ───
QByteArray ecdsaSign(const QByteArray& hash32, const QByteArray& privKey32);
bool ecdsaVerify(const QByteArray& hash32, const QByteArray& signature, const QByteArray& pubkey33);

} // namespace crypto
} // namespace omni

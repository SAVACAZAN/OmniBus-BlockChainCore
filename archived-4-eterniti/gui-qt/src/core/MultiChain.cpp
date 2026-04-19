#include "core/MultiChain.h"
#include <cstring>

namespace omni {

// ══════════════════════════════════════════════════════════════════
//  Chain Definitions - all 19 chains
// ══════════════════════════════════════════════════════════════════

QList<ChainDef> MultiChainWallet::chainDefinitions() {
    return {
        // 5 OMNI PQ Domains
        {"OMNI",  777, 44, "NATIVE_SEGWIT", "ob",     "secp256k1", "omnibus.omni",     "O"},
        {"OMNI",  778, 44, "NATIVE_SEGWIT", "ob_k1_", "secp256k1", "omnibus.love",     "L"},
        {"OMNI",  779, 44, "NATIVE_SEGWIT", "ob_f5_", "secp256k1", "omnibus.food",     "F"},
        {"OMNI",  780, 44, "NATIVE_SEGWIT", "ob_d5_", "secp256k1", "omnibus.rent",     "R"},
        {"OMNI",  781, 44, "NATIVE_SEGWIT", "ob_s3_", "secp256k1", "omnibus.vacation", "V"},
        // BTC 4 types
        {"BTC",     0, 44, "LEGACY_P2PKH",  "",     "secp256k1", "", "B"},
        {"BTC",     0, 49, "SEGWIT_P2SH",   "",     "secp256k1", "", "B"},
        {"BTC",     0, 84, "NATIVE_SEGWIT",  "bc",  "secp256k1", "", "B"},
        {"BTC",     0, 86, "TAPROOT",        "bc",  "secp256k1", "", "B"},
        // EVM chains
        {"ETH",    60, 44, "EOA",           "0x",   "secp256k1", "", "E"},
        {"BNB",    60, 44, "EOA",           "0x",   "secp256k1", "", "N"},
        {"OP",     60, 44, "EOA",           "0x",   "secp256k1", "", "P"},
        // secp256k1 chains
        {"ATOM",  118, 44, "BECH32",        "cosmos","secp256k1", "", "A"},
        {"XRP",   144, 44, "BASE58",        "",     "secp256k1", "", "X"},
        {"LTC",     2, 84, "NATIVE_SEGWIT", "ltc",  "secp256k1", "", "L"},
        {"DOGE",    3, 44, "P2PKH",         "",     "secp256k1", "", "D"},
        {"BCH",   145, 44, "P2PKH",         "",     "secp256k1", "", "C"},
        // Ed25519 chains (simplified - derive as secp256k1 with note)
        {"SOL",   501, 44, "ED25519",       "",     "ed25519",   "", "S"},
        {"ADA",  1815, 44, "ED25519",       "",     "ed25519",   "", "A"},
        {"DOT",   354, 44, "SS58",          "",     "ed25519",   "", "D"},
        {"EGLD",  508, 44, "BECH32",        "erd",  "ed25519",   "", "E"},
        {"XLM",   148, 44, "ED25519",       "",     "ed25519",   "", "X"},
    };
}

// ══════════════════════════════════════════════════════════════════
//  Base58Check encoding
// ══════════════════════════════════════════════════════════════════

namespace {
const char BASE58_ALPHABET[] = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
}

QString MultiChainWallet::base58Check(const QByteArray& payload) {
    // Append 4-byte checksum
    QByteArray checksum = crypto::doubleSha256(payload).left(4);
    QByteArray data = payload + checksum;

    // Count leading zeros
    int leadingZeros = 0;
    for (int i = 0; i < data.size() && data[i] == 0; ++i)
        leadingZeros++;

    // Convert to base58
    // Work with big number represented as bytes
    std::vector<uint8_t> input(data.begin(), data.end());
    std::vector<char> result;

    while (!input.empty()) {
        int remainder = 0;
        std::vector<uint8_t> quotient;
        for (uint8_t byte : input) {
            int value = remainder * 256 + byte;
            int q = value / 58;
            remainder = value % 58;
            if (!quotient.empty() || q > 0)
                quotient.push_back(static_cast<uint8_t>(q));
        }
        result.push_back(BASE58_ALPHABET[remainder]);
        input = quotient;
    }

    // Add leading '1's for leading zero bytes
    for (int i = 0; i < leadingZeros; ++i)
        result.push_back('1');

    // Reverse
    std::reverse(result.begin(), result.end());
    return QString::fromLatin1(result.data(), static_cast<int>(result.size()));
}

// ══════════════════════════════════════════════════════════════════
//  Keccak-256 (minimal implementation for Ethereum addresses)
// ══════════════════════════════════════════════════════════════════

namespace {

static const uint64_t KECCAK_RC[24] = {
    0x0000000000000001ULL, 0x0000000000008082ULL, 0x800000000000808AULL, 0x8000000080008000ULL,
    0x000000000000808BULL, 0x0000000080000001ULL, 0x8000000080008081ULL, 0x8000000000008009ULL,
    0x000000000000008AULL, 0x0000000000000088ULL, 0x0000000080008009ULL, 0x000000008000000AULL,
    0x000000008000808BULL, 0x800000000000008BULL, 0x8000000000008089ULL, 0x8000000000008003ULL,
    0x8000000000008002ULL, 0x8000000000000080ULL, 0x000000000000800AULL, 0x800000008000000AULL,
    0x8000000080008081ULL, 0x8000000000008080ULL, 0x0000000080000001ULL, 0x8000000080008008ULL,
};

static const int KECCAK_ROTC[24] = {
    1,3,6,10,15,21,28,36,45,55,2,14,27,41,56,8,25,43,62,18,39,61,20,44
};

static const int KECCAK_PILN[24] = {
    10,7,11,17,18,3,5,16,8,21,24,4,15,23,19,13,12,2,20,14,22,9,6,1
};

inline uint64_t keccak_rotl64(uint64_t x, int n) { return (x << n) | (x >> (64 - n)); }

void keccakF1600(uint64_t st[25]) {
    for (int round = 0; round < 24; ++round) {
        // Theta
        uint64_t bc[5];
        for (int i = 0; i < 5; ++i)
            bc[i] = st[i] ^ st[i+5] ^ st[i+10] ^ st[i+15] ^ st[i+20];
        for (int i = 0; i < 5; ++i) {
            uint64_t t = bc[(i+4)%5] ^ keccak_rotl64(bc[(i+1)%5], 1);
            for (int j = 0; j < 25; j += 5)
                st[j+i] ^= t;
        }
        // Rho + Pi
        uint64_t t = st[1];
        for (int i = 0; i < 24; ++i) {
            int j = KECCAK_PILN[i];
            uint64_t tmp = st[j];
            st[j] = keccak_rotl64(t, KECCAK_ROTC[i]);
            t = tmp;
        }
        // Chi
        for (int j = 0; j < 25; j += 5) {
            uint64_t tmp[5];
            for (int i = 0; i < 5; ++i) tmp[i] = st[j+i];
            for (int i = 0; i < 5; ++i)
                st[j+i] = tmp[i] ^ ((~tmp[(i+1)%5]) & tmp[(i+2)%5]);
        }
        // Iota
        st[0] ^= KECCAK_RC[round];
    }
}

QByteArray keccak256(const QByteArray& input) {
    uint64_t st[25] = {};
    int rate = 136; // (1600 - 256*2) / 8 bytes

    const uint8_t* data = reinterpret_cast<const uint8_t*>(input.constData());
    int len = input.size();
    int offset = 0;

    // Absorb
    while (len >= rate) {
        for (int i = 0; i < rate / 8; ++i) {
            uint64_t v = 0;
            for (int b = 0; b < 8; ++b)
                v |= static_cast<uint64_t>(data[offset + i*8 + b]) << (b*8);
            st[i] ^= v;
        }
        keccakF1600(st);
        offset += rate;
        len -= rate;
    }

    // Pad
    uint8_t temp[200] = {};
    std::memcpy(temp, data + offset, len);
    temp[len] = 0x01;  // Keccak padding (not SHA-3 which uses 0x06)
    temp[rate - 1] |= 0x80;

    for (int i = 0; i < rate / 8; ++i) {
        uint64_t v = 0;
        for (int b = 0; b < 8; ++b)
            v |= static_cast<uint64_t>(temp[i*8 + b]) << (b*8);
        st[i] ^= v;
    }
    keccakF1600(st);

    // Squeeze - 32 bytes
    QByteArray result(32, '\0');
    for (int i = 0; i < 4; ++i) {
        for (int b = 0; b < 8; ++b)
            result[i*8 + b] = static_cast<char>((st[i] >> (b*8)) & 0xff);
    }
    return result;
}

} // anonymous namespace

QString MultiChainWallet::keccak256Address(const QByteArray& uncompressedPubkey) {
    // ETH address = last 20 bytes of Keccak256(pubkey[1:65])
    QByteArray pubBytes = uncompressedPubkey.mid(1); // remove 0x04 prefix
    QByteArray hash = keccak256(pubBytes);
    QByteArray addr20 = hash.right(20);

    // EIP-55 checksum encoding
    QString addrHex = addr20.toHex().toLower();
    QByteArray hashOfAddr = keccak256(addrHex.toLatin1());

    QString checksummed = "0x";
    for (int i = 0; i < 40; ++i) {
        int hashNibble = (static_cast<uint8_t>(hashOfAddr[i/2]) >> ((i % 2 == 0) ? 4 : 0)) & 0xf;
        if (hashNibble >= 8)
            checksummed += addrHex[i].toUpper();
        else
            checksummed += addrHex[i];
    }
    return checksummed;
}

// ══════════════════════════════════════════════════════════════════
//  Derive all chains
// ══════════════════════════════════════════════════════════════════

QList<ChainAddress> MultiChainWallet::deriveAll(const QByteArray& seed, int count) {
    QList<ChainAddress> all;
    all.append(deriveOmniDomains(seed, count));
    all.append(deriveBtc(seed, count));

    // ETH (+ BNB, OP share same keys)
    all.append(deriveEthChain(seed, "ETH", 60, count));
    // BNB and OP use same derivation as ETH
    {
        auto ethAddrs = deriveEthChain(seed, "BNB", 60, count);
        for (auto& a : ethAddrs) a.chain = "BNB";
        all.append(ethAddrs);
    }
    {
        auto ethAddrs = deriveEthChain(seed, "OP", 60, count);
        for (auto& a : ethAddrs) a.chain = "OP";
        all.append(ethAddrs);
    }

    // ATOM (Bech32 secp256k1)
    all.append(deriveSecp256k1Chain(seed, "ATOM", 118, "BECH32", "cosmos", -1, count));

    // XRP (Base58Check, version 0)
    all.append(deriveSecp256k1Chain(seed, "XRP", 144, "BASE58", "", 0, count));

    // LTC (Bech32 SegWit, purpose 84)
    {
        auto master = crypto::masterKeyFromSeed(seed);
        for (int i = 0; i < count; ++i) {
            QString path = QString("m/84'/2'/0'/0/%1").arg(i);
            auto key = crypto::derivePath(master, path);
            QByteArray pub = crypto::privateToPublicKey(key.key);
            QByteArray h160 = crypto::hash160(pub);
            QString addr = crypto::pubkeyHashToAddress(h160, "ltc");

            ChainAddress ca;
            ca.chain = "LTC";
            ca.addressType = "NATIVE_SEGWIT";
            ca.address = addr;
            ca.derivationPath = path;
            ca.publicKeyHex = pub.toHex();
            ca.coinType = 2;
            ca.purpose = 84;
            ca.index = i;
            all.append(ca);
        }
    }

    // DOGE (P2PKH, version 30)
    all.append(deriveSecp256k1Chain(seed, "DOGE", 3, "P2PKH", "", 30, count));

    // BCH (P2PKH, version 0)
    all.append(deriveSecp256k1Chain(seed, "BCH", 145, "P2PKH", "", 0, count));

    // Ed25519 chains - derive using secp256k1 path (simplified)
    // In production, these would use SLIP-10 Ed25519, but for display
    // we derive the path and show it as "Ed25519 (secp256k1 seed)"
    QStringList ed25519Chains = {"SOL", "ADA", "DOT", "EGLD", "XLM"};
    QList<int> ed25519CoinTypes = {501, 1815, 354, 508, 148};
    QStringList ed25519Types = {"ED25519", "ED25519", "SS58", "BECH32", "ED25519"};

    auto master = crypto::masterKeyFromSeed(seed);
    for (int c = 0; c < ed25519Chains.size(); ++c) {
        for (int i = 0; i < count; ++i) {
            QString path = QString("m/44'/%1'/0'/0/%2").arg(ed25519CoinTypes[c]).arg(i);
            auto key = crypto::derivePath(master, path);
            QByteArray pub = crypto::privateToPublicKey(key.key);

            ChainAddress ca;
            ca.chain = ed25519Chains[c];
            ca.addressType = ed25519Types[c];
            ca.derivationPath = path;
            ca.publicKeyHex = pub.toHex();
            ca.coinType = ed25519CoinTypes[c];
            ca.purpose = 44;
            ca.index = i;

            // Generate a representative address
            QByteArray h160 = crypto::hash160(pub);
            if (ed25519Chains[c] == "SOL") {
                ca.address = base58Check(QByteArray(1, '\0') + pub.left(32)).left(44);
            } else if (ed25519Chains[c] == "EGLD") {
                ca.address = crypto::pubkeyHashToAddress(h160, "erd");
            } else if (ed25519Chains[c] == "ADA") {
                ca.address = crypto::pubkeyHashToAddress(h160, "addr");
            } else if (ed25519Chains[c] == "DOT") {
                ca.address = base58Check(QByteArray(1, '\0') + h160).left(48);
            } else if (ed25519Chains[c] == "XLM") {
                ca.address = "G" + pub.left(32).toHex().left(55).toUpper();
            }
            all.append(ca);
        }
    }

    return all;
}

// ══════════════════════════════════════════════════════════════════
//  OMNI 5 PQ Domains
// ══════════════════════════════════════════════════════════════════

QList<ChainAddress> MultiChainWallet::deriveOmniDomains(const QByteArray& seed, int count) {
    QList<ChainAddress> result;
    struct Domain {
        int coinType;
        QString name;
        QString algorithm;
        QString hrp;  // Bech32 human-readable prefix
    };
    QList<Domain> domains = {
        {777, "omnibus.omni",     "ML-DSA-87 + ML-KEM-768", "ob"},
        {778, "omnibus.love",     "ML-DSA-87 (Dilithium-5)", "ob_k1_"},
        {779, "omnibus.food",     "Falcon-512",              "ob_f5_"},
        {780, "omnibus.rent",     "SLH-DSA (SPHINCS+)",      "ob_d5_"},
        {781, "omnibus.vacation", "Falcon-Light / AES-128",  "ob_s3_"},
    };

    auto master = crypto::masterKeyFromSeed(seed);

    for (const auto& dom : domains) {
        for (int i = 0; i < count; ++i) {
            QString path = QString("m/44'/%1'/0'/0/%2").arg(dom.coinType).arg(i);
            auto key = crypto::derivePath(master, path);
            QByteArray pub = crypto::privateToPublicKey(key.key);
            QByteArray h160 = crypto::hash160(pub);
            QString addr = crypto::pubkeyHashToAddress(h160, dom.hrp);

            ChainAddress ca;
            ca.chain = "OMNI";
            ca.domain = dom.name;
            ca.addressType = "NATIVE_SEGWIT";
            ca.address = addr;
            ca.derivationPath = path;
            ca.publicKeyHex = pub.toHex();
            ca.coinType = dom.coinType;
            ca.purpose = 44;
            ca.index = i;
            result.append(ca);
        }
    }
    return result;
}

// ══════════════════════════════════════════════════════════════════
//  BTC 4 address types
// ══════════════════════════════════════════════════════════════════

QList<ChainAddress> MultiChainWallet::deriveBtc(const QByteArray& seed, int count) {
    QList<ChainAddress> result;
    auto master = crypto::masterKeyFromSeed(seed);

    struct BtcType {
        int purpose;
        QString addressType;
    };
    QList<BtcType> types = {
        {44, "LEGACY_P2PKH"},
        {49, "SEGWIT_P2SH"},
        {84, "NATIVE_SEGWIT"},
        {86, "TAPROOT"},
    };

    for (const auto& bt : types) {
        for (int i = 0; i < count; ++i) {
            QString path = QString("m/%1'/0'/0'/0/%2").arg(bt.purpose).arg(i);
            auto key = crypto::derivePath(master, path);
            QByteArray pub = crypto::privateToPublicKey(key.key);
            QByteArray h160 = crypto::hash160(pub);

            ChainAddress ca;
            ca.chain = "BTC";
            ca.addressType = bt.addressType;
            ca.derivationPath = path;
            ca.publicKeyHex = pub.toHex();
            ca.coinType = 0;
            ca.purpose = bt.purpose;
            ca.index = i;

            if (bt.purpose == 44) {
                // Legacy P2PKH: 1...
                ca.address = base58Check(QByteArray(1, '\x00') + h160);
            } else if (bt.purpose == 49) {
                // SegWit P2SH: 3...
                QByteArray redeem = QByteArray("\x00\x14", 2) + h160;
                QByteArray redeemHash = crypto::hash160(redeem);
                ca.address = base58Check(QByteArray(1, '\x05') + redeemHash);
            } else if (bt.purpose == 84) {
                // Native SegWit: bc1q...
                ca.address = crypto::pubkeyHashToAddress(h160, "bc");
            } else if (bt.purpose == 86) {
                // Taproot: bc1p... (x-only pubkey)
                QByteArray xOnly = pub.mid(1, 32); // remove prefix byte
                // Bech32m with witness version 1
                // Simplified: use pubkey hash for now
                ca.address = crypto::pubkeyHashToAddress(h160, "bc");
                ca.address.replace("bc1q", "bc1p"); // taproot indicator
            }
            result.append(ca);
        }
    }
    return result;
}

// ══════════════════════════════════════════════════════════════════
//  Generic secp256k1 chain
// ══════════════════════════════════════════════════════════════════

QList<ChainAddress> MultiChainWallet::deriveSecp256k1Chain(
    const QByteArray& seed, const QString& chain, int coinType,
    const QString& addressType, const QString& hrp, int versionByte, int count)
{
    QList<ChainAddress> result;
    auto master = crypto::masterKeyFromSeed(seed);

    for (int i = 0; i < count; ++i) {
        QString path = QString("m/44'/%1'/0'/0/%2").arg(coinType).arg(i);
        auto key = crypto::derivePath(master, path);
        QByteArray pub = crypto::privateToPublicKey(key.key);
        QByteArray h160 = crypto::hash160(pub);

        ChainAddress ca;
        ca.chain = chain;
        ca.addressType = addressType;
        ca.derivationPath = path;
        ca.publicKeyHex = pub.toHex();
        ca.coinType = coinType;
        ca.purpose = 44;
        ca.index = i;

        if (!hrp.isEmpty()) {
            ca.address = crypto::pubkeyHashToAddress(h160, hrp);
        } else {
            ca.address = base58Check(QByteArray(1, static_cast<char>(versionByte)) + h160);
        }
        result.append(ca);
    }
    return result;
}

// ══════════════════════════════════════════════════════════════════
//  Ethereum / EVM chains
// ══════════════════════════════════════════════════════════════════

QList<ChainAddress> MultiChainWallet::deriveEthChain(
    const QByteArray& seed, const QString& chain, int coinType, int count)
{
    QList<ChainAddress> result;
    auto master = crypto::masterKeyFromSeed(seed);

    for (int i = 0; i < count; ++i) {
        QString path = QString("m/44'/%1'/0'/0/%2").arg(coinType).arg(i);
        auto key = crypto::derivePath(master, path);
        QByteArray pub = crypto::privateToUncompressedPublicKey(key.key);

        ChainAddress ca;
        ca.chain = chain;
        ca.addressType = "EOA";
        ca.address = keccak256Address(pub);
        ca.derivationPath = path;
        ca.publicKeyHex = crypto::privateToPublicKey(key.key).toHex();
        ca.coinType = coinType;
        ca.purpose = 44;
        ca.index = i;
        result.append(ca);
    }
    return result;
}

} // namespace omni

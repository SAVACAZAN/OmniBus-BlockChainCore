#pragma once

#include <QString>
#include <QList>
#include <QByteArray>
#include "core/LocalCrypto.h"

namespace omni {

// ─── Chain address entry ───
struct ChainAddress {
    QString chain;          // "OMNI", "BTC", "ETH", etc.
    QString domain;         // "omnibus.omni", "" for non-OMNI
    QString addressType;    // "NATIVE_SEGWIT", "P2PKH", "EOA", "ED25519", etc.
    QString address;
    QString derivationPath;
    QString publicKeyHex;
    int coinType = 0;
    int purpose = 44;
    int index = 0;
};

// ─── Chain definition ───
struct ChainDef {
    QString name;
    int coinType;
    int purpose;
    QString addressType;
    QString prefix;         // Bech32 HRP or version byte info
    QString algorithm;      // "secp256k1", "ed25519"
    QString domain;         // OMNI domain name (empty for other chains)
    QString icon;           // emoji/symbol for display
};

// ─── Multi-chain wallet generator ───
class MultiChainWallet {
public:
    // Generate all addresses from a BIP-39 seed
    static QList<ChainAddress> deriveAll(const QByteArray& seed, int addressesPerAccount = 1);

    // Get the chain definitions
    static QList<ChainDef> chainDefinitions();

private:
    // OMNI domains (5)
    static QList<ChainAddress> deriveOmniDomains(const QByteArray& seed, int count);

    // BTC (4 purpose types)
    static QList<ChainAddress> deriveBtc(const QByteArray& seed, int count);

    // secp256k1-based chains (ETH, ATOM, XRP, LTC, DOGE, BCH, BNB, OP)
    static QList<ChainAddress> deriveSecp256k1Chain(const QByteArray& seed,
        const QString& chain, int coinType, const QString& addressType,
        const QString& hrp, int versionByte, int count);

    // Ethereum-style (Keccak256)
    static QList<ChainAddress> deriveEthChain(const QByteArray& seed,
        const QString& chain, int coinType, int count);

    // Address encoding helpers
    static QString base58Check(const QByteArray& payload);
    static QString keccak256Address(const QByteArray& uncompressedPubkey);
};

} // namespace omni

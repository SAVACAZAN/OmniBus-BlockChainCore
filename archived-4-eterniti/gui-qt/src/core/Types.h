#pragma once

#include <QString>
#include <QList>
#include <QJsonObject>
#include <cstdint>

namespace omni {

// 1 OMNI = 1,000,000,000 SAT
constexpr qint64 SAT_PER_OMNI = 1'000'000'000LL;
constexpr qint64 MAX_SUPPLY_SAT = 21'000'000LL * SAT_PER_OMNI;

inline QString satToOmni(qint64 sat) {
    bool negative = sat < 0;
    qint64 abs = negative ? -sat : sat;
    qint64 whole = abs / SAT_PER_OMNI;
    qint64 frac = abs % SAT_PER_OMNI;
    QString s = QString("%1%2.%3")
        .arg(negative ? "-" : "")
        .arg(whole)
        .arg(frac, 9, 10, QChar('0'));
    // Trim trailing zeros but keep at least 4 decimal places
    while (s.endsWith('0') && s.indexOf('.') < s.length() - 5)
        s.chop(1);
    return s;
}

inline qint64 omniToSat(double omni) {
    return static_cast<qint64>(omni * SAT_PER_OMNI);
}

struct BlockData {
    int height = 0;
    QString hash;
    QString previousHash;
    qint64 timestamp = 0;
    int nonce = 0;
    int txCount = 0;
    QString miner;
    qint64 rewardSAT = 0;
    int difficulty = 0;

    static BlockData fromJson(const QJsonObject& obj);
};

struct TransactionData {
    QString txid;
    QString from;
    QString to;
    qint64 amountSAT = 0;
    qint64 feeSAT = 0;
    int confirmations = 0;
    int blockHeight = -1;
    QString status;      // "pending" or "confirmed"
    QString direction;   // "sent" or "received"
    qint64 timestamp = 0;
    QString opReturn;

    static TransactionData fromJson(const QJsonObject& obj);
};

struct PeerInfo {
    QString id;
    QString host;
    int port = 0;
    bool alive = false;

    static PeerInfo fromJson(const QJsonObject& obj);
};

struct MinerInfo {
    QString miner;
    int blocksMined = 0;
    qint64 totalRewardSAT = 0;
    qint64 currentBalanceSAT = 0;

    static MinerInfo fromJson(const QJsonObject& obj);
};

struct NetworkInfo {
    QString chain;
    QString version;
    int blockHeight = 0;
    qint64 blockRewardSAT = 0;
    int difficulty = 0;
    int mempoolSize = 0;
    int peerCount = 0;
    QString nodeAddress;
    qint64 nodeBalance = 0;
    int halvingInterval = 0;
    qint64 maxSupply = 0;
    int blockTimeMs = 0;
    int subBlocksPerBlock = 0;

    static NetworkInfo fromJson(const QJsonObject& obj);
};

struct MempoolStats {
    int size = 0;
    int maxTx = 0;
    int maxBytes = 0;
    int bytes = 0;

    static MempoolStats fromJson(const QJsonObject& obj);
};

struct FeeEstimate {
    qint64 medianFee = 0;
    qint64 minFee = 0;
    double burnPct = 0.0;

    static FeeEstimate fromJson(const QJsonObject& obj);
};

struct WalletInfo {
    QString address;
    qint64 balanceSAT = 0;
    QString balanceOMNI;
    int nodeHeight = 0;

    static WalletInfo fromJson(const QJsonObject& obj);
};

} // namespace omni

#include "core/Types.h"
#include <QJsonObject>
#include <QJsonArray>

namespace omni {

BlockData BlockData::fromJson(const QJsonObject& obj) {
    BlockData b;
    b.height     = obj["height"].toInt();
    b.hash       = obj["hash"].toString();
    b.previousHash = obj["previousHash"].toString();
    b.timestamp  = static_cast<qint64>(obj["timestamp"].toDouble());
    b.nonce      = obj["nonce"].toInt();
    b.txCount    = obj["txCount"].toInt();
    b.miner      = obj["miner"].toString();
    b.rewardSAT  = static_cast<qint64>(obj["rewardSAT"].toDouble());
    if (b.rewardSAT == 0)
        b.rewardSAT = static_cast<qint64>(obj["reward_sat"].toDouble());
    b.difficulty = obj["difficulty"].toInt();
    return b;
}

TransactionData TransactionData::fromJson(const QJsonObject& obj) {
    TransactionData t;
    t.txid          = obj["txid"].toString();
    t.from          = obj["from"].toString();
    t.to            = obj["to"].toString();
    t.amountSAT     = static_cast<qint64>(obj["amount"].toDouble());
    if (t.amountSAT == 0)
        t.amountSAT = static_cast<qint64>(obj["amount_sat"].toDouble());
    t.feeSAT        = static_cast<qint64>(obj["fee"].toDouble());
    t.confirmations = obj["confirmations"].toInt();
    t.blockHeight   = obj["blockHeight"].toInt(-1);
    t.status        = obj["status"].toString("pending");
    t.direction     = obj["direction"].toString();
    t.timestamp     = static_cast<qint64>(obj["timestamp"].toDouble());
    t.opReturn      = obj["op_return"].toString();
    return t;
}

PeerInfo PeerInfo::fromJson(const QJsonObject& obj) {
    PeerInfo p;
    p.id    = obj["id"].toString();
    p.host  = obj["host"].toString();
    p.port  = obj["port"].toInt();
    p.alive = obj["alive"].toBool();
    return p;
}

MinerInfo MinerInfo::fromJson(const QJsonObject& obj) {
    MinerInfo m;
    m.miner            = obj["miner"].toString();
    m.blocksMined      = obj["blocksMined"].toInt();
    m.totalRewardSAT   = static_cast<qint64>(obj["totalRewardSAT"].toDouble());
    m.currentBalanceSAT = static_cast<qint64>(obj["currentBalanceSAT"].toDouble());
    return m;
}

NetworkInfo NetworkInfo::fromJson(const QJsonObject& obj) {
    NetworkInfo n;
    n.chain            = obj["chain"].toString();
    n.version          = obj["version"].toString();
    n.blockHeight      = obj["blockHeight"].toInt();
    n.blockRewardSAT   = static_cast<qint64>(obj["blockRewardSAT"].toDouble());
    n.difficulty        = obj["difficulty"].toInt();
    n.mempoolSize       = obj["mempoolSize"].toInt();
    n.peerCount         = obj["peerCount"].toInt();
    n.nodeAddress       = obj["nodeAddress"].toString();
    n.nodeBalance       = static_cast<qint64>(obj["nodeBalance"].toDouble());
    n.halvingInterval   = obj["halvingInterval"].toInt();
    n.maxSupply         = static_cast<qint64>(obj["maxSupply"].toDouble());
    n.blockTimeMs       = obj["blockTimeMs"].toInt();
    n.subBlocksPerBlock = obj["subBlocksPerBlock"].toInt();
    return n;
}

MempoolStats MempoolStats::fromJson(const QJsonObject& obj) {
    MempoolStats m;
    m.size     = obj["size"].toInt();
    m.maxTx    = obj["maxTx"].toInt();
    m.maxBytes = obj["maxBytes"].toInt();
    m.bytes    = obj["bytes"].toInt();
    return m;
}

FeeEstimate FeeEstimate::fromJson(const QJsonObject& obj) {
    FeeEstimate f;
    f.medianFee = static_cast<qint64>(obj["medianFee"].toDouble());
    f.minFee    = static_cast<qint64>(obj["minFee"].toDouble());
    f.burnPct   = obj["burnPct"].toDouble();
    return f;
}

WalletInfo WalletInfo::fromJson(const QJsonObject& obj) {
    WalletInfo w;
    w.address    = obj["address"].toString();
    w.balanceSAT = static_cast<qint64>(obj["balance"].toDouble());
    w.balanceOMNI = obj["balanceOMNI"].toString();
    w.nodeHeight = obj["nodeHeight"].toInt();
    return w;
}

} // namespace omni

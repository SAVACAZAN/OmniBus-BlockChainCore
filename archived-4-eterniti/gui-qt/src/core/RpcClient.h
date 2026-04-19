#pragma once

#include <QObject>
#include <QNetworkAccessManager>
#include <QJsonObject>
#include <QJsonArray>
#include <functional>

namespace omni {

using RpcCallback = std::function<void(const QJsonValue& result, const QString& error)>;

class RpcClient : public QObject {
    Q_OBJECT
public:
    explicit RpcClient(QObject* parent = nullptr);

    void setEndpoint(const QString& host, int port);

    // Raw request for console
    void rawRequest(const QString& method, const QJsonArray& params, RpcCallback cb);

    // Blockchain
    void getBlockCount(RpcCallback cb);
    void getLatestBlock(RpcCallback cb);
    void getBlock(int index, RpcCallback cb);
    void getBlocks(int fromHeight, int count, RpcCallback cb);
    void getHeaders(int fromHeight, int count, RpcCallback cb);
    void getStatus(RpcCallback cb);
    void getPerformance(RpcCallback cb);
    void getMerkleProof(const QString& txid, RpcCallback cb);

    // Balance & Transactions
    void getBalance(RpcCallback cb);
    void getTransaction(const QString& txid, RpcCallback cb);
    void getTransactions(RpcCallback cb);
    void getAddressHistory(const QString& address, RpcCallback cb);
    void listTransactions(int count, RpcCallback cb);
    void sendTransaction(const QString& to, qint64 amountSat, RpcCallback cb);
    void sendOpReturn(const QString& data, qint64 feeSat, RpcCallback cb);
    void getNonce(const QString& address, RpcCallback cb);

    // Mempool
    void getMempoolSize(RpcCallback cb);
    void getMempoolStats(RpcCallback cb);

    // Network
    void getNetworkInfo(RpcCallback cb);
    void getPeers(RpcCallback cb);
    void getSyncStatus(RpcCallback cb);
    void getNodeList(RpcCallback cb);

    // Mining
    void getMinerInfo(RpcCallback cb);
    void getMinerStats(RpcCallback cb);
    void getPoolStats(RpcCallback cb);
    void registerMiner(const QJsonObject& data, RpcCallback cb);
    void estimateFee(RpcCallback cb);
    void minerSendTx(const QString& from, const QString& to, qint64 amount, qint64 fee, RpcCallback cb);

    // Staking
    void getStakingInfo(const QString& addr, RpcCallback cb);
    void getSlashHistory(const QString& addr, RpcCallback cb);
    void submitSlashEvidence(const QJsonObject& evidence, RpcCallback cb);

private:
    void sendRequest(const QString& method, const QJsonArray& params, RpcCallback cb);

    QNetworkAccessManager m_nam;
    QString m_url;
    int m_requestId = 1;
};

} // namespace omni

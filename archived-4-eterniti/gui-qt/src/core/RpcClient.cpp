#include "core/RpcClient.h"
#include "core/Settings.h"
#include <QNetworkRequest>
#include <QNetworkReply>
#include <QJsonDocument>

namespace omni {

RpcClient::RpcClient(QObject* parent)
    : QObject(parent)
{
    auto& s = Settings::instance();
    setEndpoint(s.rpcHost(), s.rpcPort());
}

void RpcClient::setEndpoint(const QString& host, int port) {
    m_url = QString("http://%1:%2/").arg(host).arg(port);
}

void RpcClient::sendRequest(const QString& method, const QJsonArray& params, RpcCallback cb) {
    QJsonObject body;
    body["jsonrpc"] = "2.0";
    body["method"]  = method;
    body["params"]  = params;
    body["id"]      = m_requestId++;

    QNetworkRequest req{QUrl(m_url)};
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    req.setTransferTimeout(10000);

    QNetworkReply* reply = m_nam.post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));

    connect(reply, &QNetworkReply::finished, this, [reply, cb]() {
        reply->deleteLater();

        if (reply->error() != QNetworkReply::NoError) {
            if (cb) cb(QJsonValue(), reply->errorString());
            return;
        }

        QByteArray data = reply->readAll();
        QJsonParseError parseErr;
        QJsonDocument doc = QJsonDocument::fromJson(data, &parseErr);

        if (parseErr.error != QJsonParseError::NoError) {
            if (cb) cb(QJsonValue(), "JSON parse error: " + parseErr.errorString());
            return;
        }

        QJsonObject obj = doc.object();
        if (obj.contains("error") && !obj["error"].isNull()) {
            QJsonObject err = obj["error"].toObject();
            if (cb) cb(QJsonValue(), err["message"].toString("Unknown RPC error"));
            return;
        }

        if (cb) cb(obj["result"], QString());
    });
}

void RpcClient::rawRequest(const QString& method, const QJsonArray& params, RpcCallback cb) {
    sendRequest(method, params, cb);
}

// Blockchain
void RpcClient::getBlockCount(RpcCallback cb) { sendRequest("getblockcount", {}, cb); }
void RpcClient::getLatestBlock(RpcCallback cb) { sendRequest("getlatestblock", {}, cb); }
void RpcClient::getBlock(int index, RpcCallback cb) { sendRequest("getblock", QJsonArray{index}, cb); }
void RpcClient::getBlocks(int from, int count, RpcCallback cb) { sendRequest("getblocks", QJsonArray{from, count}, cb); }
void RpcClient::getHeaders(int from, int count, RpcCallback cb) { sendRequest("getheaders", QJsonArray{from, count}, cb); }
void RpcClient::getStatus(RpcCallback cb) { sendRequest("getstatus", {}, cb); }
void RpcClient::getPerformance(RpcCallback cb) { sendRequest("getperformance", {}, cb); }
void RpcClient::getMerkleProof(const QString& txid, RpcCallback cb) { sendRequest("getmerkleproof", QJsonArray{txid}, cb); }

// Balance & Transactions
void RpcClient::getBalance(RpcCallback cb) { sendRequest("getbalance", {}, cb); }
void RpcClient::getTransaction(const QString& txid, RpcCallback cb) { sendRequest("gettransaction", QJsonArray{txid}, cb); }
void RpcClient::getTransactions(RpcCallback cb) { sendRequest("gettransactions", {}, cb); }
void RpcClient::getAddressHistory(const QString& addr, RpcCallback cb) { sendRequest("getaddresshistory", QJsonArray{addr}, cb); }
void RpcClient::listTransactions(int count, RpcCallback cb) { sendRequest("listtransactions", QJsonArray{count}, cb); }
void RpcClient::sendTransaction(const QString& to, qint64 amountSat, RpcCallback cb) { sendRequest("sendtransaction", QJsonArray{to, amountSat}, cb); }
void RpcClient::sendOpReturn(const QString& data, qint64 feeSat, RpcCallback cb) { sendRequest("sendopreturn", QJsonArray{data, feeSat}, cb); }
void RpcClient::getNonce(const QString& addr, RpcCallback cb) { sendRequest("getnonce", QJsonArray{addr}, cb); }

// Mempool
void RpcClient::getMempoolSize(RpcCallback cb) { sendRequest("getmempoolsize", {}, cb); }
void RpcClient::getMempoolStats(RpcCallback cb) { sendRequest("getmempoolstats", {}, cb); }

// Network
void RpcClient::getNetworkInfo(RpcCallback cb) { sendRequest("getnetworkinfo", {}, cb); }
void RpcClient::getPeers(RpcCallback cb) { sendRequest("getpeers", {}, cb); }
void RpcClient::getSyncStatus(RpcCallback cb) { sendRequest("getsyncstatus", {}, cb); }
void RpcClient::getNodeList(RpcCallback cb) { sendRequest("getnodelist", {}, cb); }

// Mining
void RpcClient::getMinerInfo(RpcCallback cb) { sendRequest("getminerinfo", {}, cb); }
void RpcClient::getMinerStats(RpcCallback cb) { sendRequest("getminerstats", {}, cb); }
void RpcClient::getPoolStats(RpcCallback cb) { sendRequest("getpoolstats", {}, cb); }
void RpcClient::registerMiner(const QJsonObject& data, RpcCallback cb) { sendRequest("registerminer", QJsonArray{data}, cb); }
void RpcClient::estimateFee(RpcCallback cb) { sendRequest("estimatefee", {}, cb); }
void RpcClient::minerSendTx(const QString& from, const QString& to, qint64 amount, qint64 fee, RpcCallback cb) {
    sendRequest("minersendtx", QJsonArray{from, to, amount, fee}, cb);
}

// Staking
void RpcClient::getStakingInfo(const QString& addr, RpcCallback cb) { sendRequest("getstakinginfo", QJsonArray{addr}, cb); }
void RpcClient::getSlashHistory(const QString& addr, RpcCallback cb) { sendRequest("getslashhistory", QJsonArray{addr}, cb); }
void RpcClient::submitSlashEvidence(const QJsonObject& evidence, RpcCallback cb) { sendRequest("submitslashevidence", QJsonArray{evidence}, cb); }

} // namespace omni

#pragma once

#include <QObject>
#include <QTimer>
#include "core/Types.h"
#include "core/RpcClient.h"
#include "core/WebSocketClient.h"

namespace omni {

class TransactionTableModel;
class BlockTableModel;
class PeerTableModel;
class MinerTableModel;

class NodeService : public QObject {
    Q_OBJECT
public:
    static NodeService& instance();

    void start();
    void stop();

    RpcClient*       rpc()  { return &m_rpc; }
    WebSocketClient* ws()   { return &m_ws; }

    // Current state
    WalletInfo      walletInfo() const { return m_wallet; }
    NetworkInfo     networkInfo() const { return m_network; }
    MempoolStats    mempoolStats() const { return m_mempool; }
    int             blockHeight() const { return m_blockHeight; }
    bool            wsConnected() const { return m_ws.isConnected(); }

signals:
    void walletUpdated(const WalletInfo& info);
    void networkUpdated(const NetworkInfo& info);
    void mempoolUpdated(const MempoolStats& stats);
    void blockHeightChanged(int height);
    void newBlockReceived(const BlockData& block);
    void newTxReceived(const QString& txid, const QString& from, qint64 amountSat);
    void wsConnectionChanged(bool connected);
    void nodeOffline();
    void nodeOnline();

private:
    explicit NodeService(QObject* parent = nullptr);

    void fetchInitialData();
    void pollData();
    void pollMinersAndNetwork();

    void onWsBlock(const BlockData& block);
    void onWsTx(const QString& txid, const QString& from, qint64 amountSat);
    void onWsStatus(int height, int difficulty);
    void onWsConnChanged(bool connected);

    RpcClient       m_rpc;
    WebSocketClient m_ws;
    QTimer          m_pollTimer;        // 10s fallback
    QTimer          m_minerTimer;       // 30s miner/network refresh

    WalletInfo      m_wallet;
    NetworkInfo     m_network;
    MempoolStats    m_mempool;
    int             m_blockHeight = 0;
    bool            m_nodeOnline = false;
};

} // namespace omni

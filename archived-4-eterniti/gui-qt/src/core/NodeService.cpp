#include "core/NodeService.h"
#include "core/Settings.h"

namespace omni {

NodeService& NodeService::instance() {
    static NodeService svc;
    return svc;
}

NodeService::NodeService(QObject* parent)
    : QObject(parent)
{
    // WS signals
    connect(&m_ws, &WebSocketClient::newBlock, this, &NodeService::onWsBlock);
    connect(&m_ws, &WebSocketClient::newTransaction, this, &NodeService::onWsTx);
    connect(&m_ws, &WebSocketClient::statusUpdate, this, &NodeService::onWsStatus);
    connect(&m_ws, &WebSocketClient::connectionChanged, this, &NodeService::onWsConnChanged);

    // Poll timers
    connect(&m_pollTimer, &QTimer::timeout, this, &NodeService::pollData);
    connect(&m_minerTimer, &QTimer::timeout, this, &NodeService::pollMinersAndNetwork);
}

void NodeService::start() {
    auto& s = Settings::instance();
    m_rpc.setEndpoint(s.rpcHost(), s.rpcPort());
    m_ws.connectToNode(s.rpcHost(), s.wsPort());

    fetchInitialData();

    m_minerTimer.start(30000);
    // Poll timer starts only when WS is down (see onWsConnChanged)
}

void NodeService::stop() {
    m_pollTimer.stop();
    m_minerTimer.stop();
    m_ws.disconnect();
}

void NodeService::fetchInitialData() {
    // Fetch balance
    m_rpc.getBalance([this](const QJsonValue& result, const QString& err) {
        if (!err.isEmpty()) {
            if (m_nodeOnline) { m_nodeOnline = false; emit nodeOffline(); }
            return;
        }
        if (!m_nodeOnline) { m_nodeOnline = true; emit nodeOnline(); }

        m_wallet = WalletInfo::fromJson(result.toObject());
        emit walletUpdated(m_wallet);
    });

    // Fetch mempool
    m_rpc.getMempoolStats([this](const QJsonValue& result, const QString& err) {
        if (err.isEmpty()) {
            m_mempool = MempoolStats::fromJson(result.toObject());
            emit mempoolUpdated(m_mempool);
        }
    });

    // Fetch network info
    m_rpc.getNetworkInfo([this](const QJsonValue& result, const QString& err) {
        if (err.isEmpty()) {
            m_network = NetworkInfo::fromJson(result.toObject());
            m_blockHeight = m_network.blockHeight;
            emit networkUpdated(m_network);
            emit blockHeightChanged(m_blockHeight);
        }
    });
}

void NodeService::pollData() {
    // Fallback polling when WS is down
    m_rpc.getBalance([this](const QJsonValue& result, const QString& err) {
        if (!err.isEmpty()) {
            if (m_nodeOnline) { m_nodeOnline = false; emit nodeOffline(); }
            return;
        }
        if (!m_nodeOnline) { m_nodeOnline = true; emit nodeOnline(); }
        m_wallet = WalletInfo::fromJson(result.toObject());
        emit walletUpdated(m_wallet);
    });

    m_rpc.getMempoolStats([this](const QJsonValue& result, const QString& err) {
        if (err.isEmpty()) {
            m_mempool = MempoolStats::fromJson(result.toObject());
            emit mempoolUpdated(m_mempool);
        }
    });
}

void NodeService::pollMinersAndNetwork() {
    m_rpc.getNetworkInfo([this](const QJsonValue& result, const QString& err) {
        if (err.isEmpty()) {
            m_network = NetworkInfo::fromJson(result.toObject());
            m_blockHeight = m_network.blockHeight;
            emit networkUpdated(m_network);
            emit blockHeightChanged(m_blockHeight);
        }
    });

    // Also refresh balance during miner poll
    m_rpc.getBalance([this](const QJsonValue& result, const QString& err) {
        if (err.isEmpty()) {
            m_wallet = WalletInfo::fromJson(result.toObject());
            emit walletUpdated(m_wallet);
        }
    });
}

void NodeService::onWsBlock(const BlockData& block) {
    m_blockHeight = block.height;
    emit blockHeightChanged(m_blockHeight);
    emit newBlockReceived(block);
}

void NodeService::onWsTx(const QString& txid, const QString& from, qint64 amountSat) {
    emit newTxReceived(txid, from, amountSat);
}

void NodeService::onWsStatus(int height, int difficulty) {
    if (height != m_blockHeight) {
        m_blockHeight = height;
        emit blockHeightChanged(height);
    }
    m_network.difficulty = difficulty;
}

void NodeService::onWsConnChanged(bool connected) {
    emit wsConnectionChanged(connected);

    if (connected) {
        // WS is live, stop fallback polling
        m_pollTimer.stop();
        // Refresh data now that we're connected
        fetchInitialData();
    } else {
        // WS down, start fallback polling at 10s
        if (!m_pollTimer.isActive()) {
            m_pollTimer.start(10000);
        }
    }
}

} // namespace omni

#include "core/WebSocketClient.h"
#include <QJsonDocument>
#include <QJsonObject>

namespace omni {

WebSocketClient::WebSocketClient(QObject* parent)
    : QObject(parent)
{
    connect(&m_ws, &QWebSocket::connected, this, &WebSocketClient::onConnected);
    connect(&m_ws, &QWebSocket::disconnected, this, &WebSocketClient::onDisconnected);
    connect(&m_ws, &QWebSocket::textMessageReceived, this, &WebSocketClient::onTextMessage);
    connect(&m_ws, &QWebSocket::errorOccurred, this, &WebSocketClient::onError);

    m_reconnectTimer.setSingleShot(true);
    connect(&m_reconnectTimer, &QTimer::timeout, this, &WebSocketClient::tryReconnect);
}

void WebSocketClient::connectToNode(const QString& host, int port) {
    m_intentionalDisconnect = false;
    m_url = QString("ws://%1:%2").arg(host).arg(port);
    m_reconnectDelay = 3000;
    m_ws.open(QUrl(m_url));
}

void WebSocketClient::disconnect() {
    m_intentionalDisconnect = true;
    m_reconnectTimer.stop();
    m_ws.close();
}

bool WebSocketClient::isConnected() const {
    return m_connected;
}

void WebSocketClient::onConnected() {
    m_connected = true;
    m_reconnectDelay = 3000;
    emit connectionChanged(true);
}

void WebSocketClient::onDisconnected() {
    m_connected = false;
    emit connectionChanged(false);

    if (!m_intentionalDisconnect) {
        m_reconnectTimer.start(m_reconnectDelay);
        // Exponential backoff: 3s -> 6s -> 12s -> 24s -> max 30s
        m_reconnectDelay = qMin(m_reconnectDelay * 2, 30000);
    }
}

void WebSocketClient::onTextMessage(const QString& message) {
    QJsonParseError err;
    QJsonDocument doc = QJsonDocument::fromJson(message.toUtf8(), &err);
    if (err.error != QJsonParseError::NoError) return;

    QJsonObject obj = doc.object();
    QString event = obj["event"].toString();

    if (event == "new_block") {
        BlockData block;
        block.height    = obj["height"].toInt();
        block.hash      = obj["hash"].toString();
        block.rewardSAT = static_cast<qint64>(obj["reward_sat"].toDouble());
        block.difficulty = obj["difficulty"].toInt();
        block.timestamp = static_cast<qint64>(obj["timestamp"].toDouble());
        emit newBlock(block);
    }
    else if (event == "new_tx") {
        QString txid = obj["txid"].toString();
        QString from = obj["from"].toString();
        qint64 amountSat = static_cast<qint64>(obj["amount_sat"].toDouble());
        emit newTransaction(txid, from, amountSat);
    }
    else if (event == "status") {
        int height = obj["height"].toInt();
        int difficulty = obj["difficulty"].toInt();
        emit statusUpdate(height, difficulty);
    }
}

void WebSocketClient::onError(QAbstractSocket::SocketError /*error*/) {
    // Will trigger onDisconnected -> reconnect
}

void WebSocketClient::tryReconnect() {
    if (!m_intentionalDisconnect && !m_connected) {
        m_ws.open(QUrl(m_url));
    }
}

} // namespace omni

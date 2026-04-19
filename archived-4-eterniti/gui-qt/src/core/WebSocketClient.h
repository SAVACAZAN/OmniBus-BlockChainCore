#pragma once

#include <QObject>
#include <QWebSocket>
#include <QTimer>
#include "core/Types.h"

namespace omni {

class WebSocketClient : public QObject {
    Q_OBJECT
public:
    explicit WebSocketClient(QObject* parent = nullptr);

    void connectToNode(const QString& host, int port);
    void disconnect();
    bool isConnected() const;

signals:
    void newBlock(const BlockData& block);
    void newTransaction(const QString& txid, const QString& from, qint64 amountSat);
    void statusUpdate(int height, int difficulty);
    void connectionChanged(bool connected);

private slots:
    void onConnected();
    void onDisconnected();
    void onTextMessage(const QString& message);
    void onError(QAbstractSocket::SocketError error);
    void tryReconnect();

private:
    QWebSocket m_ws;
    QTimer m_reconnectTimer;
    QString m_url;
    int m_reconnectDelay = 3000;
    bool m_connected = false;
    bool m_intentionalDisconnect = false;
};

} // namespace omni

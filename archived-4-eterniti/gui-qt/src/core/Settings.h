#pragma once

#include <QSettings>
#include <QString>

namespace omni {

class Settings {
public:
    static Settings& instance();

    QString rpcHost() const;
    int     rpcPort() const;
    int     wsPort() const;
    bool    minimizeToTray() const;
    bool    notifyNewBlock() const;
    bool    notifyIncomingTx() const;

    void setRpcHost(const QString& host);
    void setRpcPort(int port);
    void setWsPort(int port);
    void setMinimizeToTray(bool v);
    void setNotifyNewBlock(bool v);
    void setNotifyIncomingTx(bool v);

private:
    Settings();
    QSettings m_settings;
};

} // namespace omni

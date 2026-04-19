#include "core/Settings.h"

namespace omni {

Settings& Settings::instance() {
    static Settings s;
    return s;
}

Settings::Settings()
    : m_settings("OmniBus", "OmniBus-Qt")
{
}

QString Settings::rpcHost() const {
    return m_settings.value("rpc/host", "127.0.0.1").toString();
}

int Settings::rpcPort() const {
    return m_settings.value("rpc/port", 8332).toInt();
}

int Settings::wsPort() const {
    return m_settings.value("ws/port", 8334).toInt();
}

bool Settings::minimizeToTray() const {
    return m_settings.value("ui/minimizeToTray", true).toBool();
}

bool Settings::notifyNewBlock() const {
    return m_settings.value("notifications/newBlock", true).toBool();
}

bool Settings::notifyIncomingTx() const {
    return m_settings.value("notifications/incomingTx", true).toBool();
}

void Settings::setRpcHost(const QString& host) {
    m_settings.setValue("rpc/host", host);
}

void Settings::setRpcPort(int port) {
    m_settings.setValue("rpc/port", port);
}

void Settings::setWsPort(int port) {
    m_settings.setValue("ws/port", port);
}

void Settings::setMinimizeToTray(bool v) {
    m_settings.setValue("ui/minimizeToTray", v);
}

void Settings::setNotifyNewBlock(bool v) {
    m_settings.setValue("notifications/newBlock", v);
}

void Settings::setNotifyIncomingTx(bool v) {
    m_settings.setValue("notifications/incomingTx", v);
}

} // namespace omni

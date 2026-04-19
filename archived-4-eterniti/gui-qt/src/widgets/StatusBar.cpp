#include "widgets/StatusBar.h"

namespace omni {

StatusBar::StatusBar(QWidget* parent)
    : QStatusBar(parent)
{
    m_heightLabel   = new QLabel("Block: 0");
    m_peersLabel    = new QLabel("Peers: 0");
    m_wsIndicator   = new QLabel("WS");
    m_syncLabel     = new QLabel("Sync: --");
    m_lastBlockLabel = new QLabel("");

    m_wsIndicator->setStyleSheet("color: #d94a4a; font-weight: bold;");

    addWidget(m_heightLabel);
    addWidget(m_peersLabel);
    addWidget(m_wsIndicator);
    addWidget(m_syncLabel);
    addPermanentWidget(m_lastBlockLabel);
}

void StatusBar::setBlockHeight(int height) {
    m_heightLabel->setText(QString("Block: %1").arg(height));
}

void StatusBar::setPeerCount(int count) {
    m_peersLabel->setText(QString("Peers: %1").arg(count));
}

void StatusBar::setWsConnected(bool connected) {
    if (connected) {
        m_wsIndicator->setText("WS: Connected");
        m_wsIndicator->setStyleSheet("color: #00b3a4; font-weight: bold;");
    } else {
        m_wsIndicator->setText("WS: Disconnected");
        m_wsIndicator->setStyleSheet("color: #d94a4a; font-weight: bold;");
    }
}

void StatusBar::setSyncPercent(double pct) {
    if (pct >= 100.0)
        m_syncLabel->setText("Synced");
    else
        m_syncLabel->setText(QString("Sync: %1%").arg(pct, 0, 'f', 1));
}

void StatusBar::setLastBlockTime(const QString& time) {
    m_lastBlockLabel->setText(time.isEmpty() ? "" : "Last block: " + time);
}

} // namespace omni

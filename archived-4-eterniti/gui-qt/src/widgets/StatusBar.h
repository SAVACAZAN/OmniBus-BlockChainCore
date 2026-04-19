#pragma once

#include <QStatusBar>
#include <QLabel>

namespace omni {

class StatusBar : public QStatusBar {
    Q_OBJECT
public:
    explicit StatusBar(QWidget* parent = nullptr);

public slots:
    void setBlockHeight(int height);
    void setPeerCount(int count);
    void setWsConnected(bool connected);
    void setSyncPercent(double pct);
    void setLastBlockTime(const QString& time);

private:
    QLabel* m_heightLabel;
    QLabel* m_peersLabel;
    QLabel* m_wsIndicator;
    QLabel* m_syncLabel;
    QLabel* m_lastBlockLabel;
};

} // namespace omni

#pragma once

#include <QSystemTrayIcon>
#include <QMenu>
#include "core/Types.h"

namespace omni {

class TrayIcon : public QSystemTrayIcon {
    Q_OBJECT
public:
    explicit TrayIcon(QWidget* mainWindow, QObject* parent = nullptr);

public slots:
    void onNewBlock(const BlockData& block);
    void onNewTx(const QString& txid, const QString& from, qint64 amountSat);

private:
    QMenu* m_menu;
    QWidget* m_mainWindow;
};

} // namespace omni

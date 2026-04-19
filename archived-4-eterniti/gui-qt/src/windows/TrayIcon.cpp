#include "windows/TrayIcon.h"
#include "core/Settings.h"
#include "core/NodeService.h"

#include <QApplication>
#include <QStyle>

namespace omni {

TrayIcon::TrayIcon(QWidget* mainWindow, QObject* parent)
    : QSystemTrayIcon(parent)
    , m_mainWindow(mainWindow)
{
    // Use application-default icon (can be replaced with custom .ico)
    setIcon(QApplication::style()->standardIcon(QStyle::SP_ComputerIcon));
    setToolTip("OmniBus-Qt");

    // Context menu
    m_menu = new QMenu;
    auto* showAction = m_menu->addAction("Show OmniBus-Qt");
    m_menu->addSeparator();
    auto* quitAction = m_menu->addAction("Quit");

    setContextMenu(m_menu);

    connect(showAction, &QAction::triggered, this, [this]() {
        m_mainWindow->show();
        m_mainWindow->raise();
        m_mainWindow->activateWindow();
    });

    connect(quitAction, &QAction::triggered, qApp, &QApplication::quit);

    connect(this, &QSystemTrayIcon::activated, this, [this](ActivationReason reason) {
        if (reason == DoubleClick) {
            m_mainWindow->show();
            m_mainWindow->raise();
            m_mainWindow->activateWindow();
        }
    });

    // Connect to NodeService signals
    auto& svc = NodeService::instance();
    connect(&svc, &NodeService::newBlockReceived, this, &TrayIcon::onNewBlock);
    connect(&svc, &NodeService::newTxReceived, this, &TrayIcon::onNewTx);

    show();
}

void TrayIcon::onNewBlock(const BlockData& block) {
    if (!Settings::instance().notifyNewBlock()) return;

    showMessage("New Block Mined",
        QString("Block #%1 — Reward: %2 OMNI")
            .arg(block.height)
            .arg(satToOmni(block.rewardSAT)),
        QSystemTrayIcon::Information, 3000);
}

void TrayIcon::onNewTx(const QString& txid, const QString& from, qint64 amountSat) {
    if (!Settings::instance().notifyIncomingTx()) return;

    showMessage("Incoming Transaction",
        QString("Received %1 OMNI\nFrom: %2")
            .arg(satToOmni(amountSat), from.left(20) + "..."),
        QSystemTrayIcon::Information, 3000);
}

} // namespace omni

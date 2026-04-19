#include "windows/MainWindow.h"
#include "windows/TrayIcon.h"
#include "widgets/StatusBar.h"
#include "widgets/OverviewTab.h"
#include "widgets/SendTab.h"
#include "widgets/ReceiveTab.h"
#include "widgets/TransactionsTab.h"
#include "widgets/MiningTab.h"
#include "widgets/NetworkTab.h"
#include "widgets/BlockExplorerTab.h"
#include "widgets/ConsoleTab.h"
#include "widgets/MultiWalletTab.h"
#include "widgets/ExchangeKeysTab.h"
#include "dialogs/AboutDialog.h"
#include "dialogs/SettingsDialog.h"
#include "dialogs/UnlockDialog.h"
#include "dialogs/CreateWalletDialog.h"
#include "dialogs/ImportWalletDialog.h"
#include "core/NodeService.h"
#include "core/Settings.h"
#include "core/WalletManager.h"
#include "core/VaultStorage.h"

#include <QMenuBar>
#include <QMessageBox>
#include <QApplication>
#include <QSettings>
#include <QClipboard>

namespace omni {

MainWindow::MainWindow(AppMode mode, QWidget* parent)
    : QMainWindow(parent), m_mode(mode)
{
    setWindowTitle("OmniBus-Qt — Blockchain Wallet");
    resize(1200, 800);
    setMinimumSize(900, 600);

    // Restore geometry
    QSettings settings("OmniBus", "OmniBus-Qt");
    restoreGeometry(settings.value("geometry").toByteArray());
    restoreState(settings.value("windowState").toByteArray());

    setupMenuBar();
    setupWalletToolbar();
    setupTabs();

    // Status bar
    m_statusBar = new StatusBar(this);
    setStatusBar(m_statusBar);

    // System tray
    m_trayIcon = new TrayIcon(this, this);

    connectSignals();

    // Update title based on mode
    if (m_mode == WalletMode) {
        auto& wm = WalletManager::instance();
        if (wm.isUnlocked()) {
            setWindowTitle(QString("OmniBus-Qt — %1").arg(wm.currentWalletName()));
        }
    }
}

void MainWindow::setAppMode(AppMode mode) {
    m_mode = mode;
    m_walletToolbar->setVisible(mode == WalletMode);
}

void MainWindow::setupWalletToolbar() {
    m_walletToolbar = addToolBar("Wallet");
    m_walletToolbar->setMovable(false);
    m_walletToolbar->setIconSize(QSize(16, 16));
    m_walletToolbar->setStyleSheet(
        "QToolBar { background: #0d0f1a; border-bottom: 1px solid #2a2d44; padding: 4px 8px; spacing: 8px; }"
    );

    // Wallet selector combo
    auto* walletLabel = new QLabel(" Wallet: ");
    walletLabel->setStyleSheet("color: #8888aa; font-weight: bold;");
    m_walletToolbar->addWidget(walletLabel);

    m_walletCombo = new QComboBox;
    m_walletCombo->setMinimumWidth(180);
    m_walletCombo->setStyleSheet(
        "QComboBox { background: #1a1d2e; color: #e0e0f0; border: 1px solid #3a3d54; "
        "border-radius: 4px; padding: 4px 8px; min-height: 24px; }"
    );
    m_walletToolbar->addWidget(m_walletCombo);

    m_walletToolbar->addSeparator();

    // Address display
    m_walletAddrLabel = new QLabel;
    m_walletAddrLabel->setStyleSheet(
        "color: #7b61ff; font-family: 'Consolas', monospace; font-size: 12px; padding: 0 8px;"
    );
    m_walletAddrLabel->setCursor(Qt::PointingHandCursor);
    m_walletAddrLabel->setToolTip("Click to copy address");
    m_walletToolbar->addWidget(m_walletAddrLabel);

    m_walletToolbar->addSeparator();

    // Balance display
    m_walletBalanceLabel = new QLabel;
    m_walletBalanceLabel->setStyleSheet(
        "color: #00b3a4; font-size: 13px; font-weight: bold; padding: 0 8px;"
    );
    m_walletToolbar->addWidget(m_walletBalanceLabel);

    // Spacer
    auto* spacer = new QWidget;
    spacer->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Preferred);
    m_walletToolbar->addWidget(spacer);

    // New Address button
    auto* newAddrAction = m_walletToolbar->addAction("+ Address");
    connect(newAddrAction, &QAction::triggered, this, [this]() {
        auto& wm = WalletManager::instance();
        if (!wm.isUnlocked()) return;
        auto addr = wm.generateAddress();
        if (!addr.address.isEmpty()) {
            refreshWalletToolbar();
            QMessageBox::information(this, "New Address",
                QString("Generated address:\n%1").arg(addr.address));
        }
    });

    // Lock button
    auto* lockAction = m_walletToolbar->addAction("Lock");
    connect(lockAction, &QAction::triggered, this, [this]() {
        WalletManager::instance().lock();
        QMessageBox::information(this, "Locked", "Wallet has been locked.");
    });

    // Click on address copies it
    m_walletAddrLabel->installEventFilter(this);

    // Wallet combo switch
    connect(m_walletCombo, QOverload<int>::of(&QComboBox::currentIndexChanged), this, [this](int index) {
        if (index < 0) return;
        QString walletId = m_walletCombo->itemData(index).toString();
        auto& wm = WalletManager::instance();
        if (walletId == wm.currentWalletId()) return;

        UnlockDialog dlg(this);
        QList<QPair<QString, QString>> wallets;
        wallets.append({walletId, m_walletCombo->itemText(index)});
        dlg.setWallets(wallets);
        if (dlg.exec() == QDialog::Accepted) {
            if (!wm.switchWallet(walletId, dlg.password())) {
                QMessageBox::warning(this, "Error", "Wrong password or corrupt wallet file.");
                refreshWalletToolbar(); // revert combo
            } else {
                refreshWalletToolbar();
                setWindowTitle(QString("OmniBus-Qt — %1").arg(wm.currentWalletName()));
            }
        } else {
            refreshWalletToolbar(); // revert combo
        }
    });

    // Show/hide based on mode
    m_walletToolbar->setVisible(m_mode == WalletMode);

    refreshWalletToolbar();
}

void MainWindow::refreshWalletToolbar() {
    auto& wm = WalletManager::instance();

    // Block signals to prevent re-triggering currentIndexChanged
    m_walletCombo->blockSignals(true);
    m_walletCombo->clear();

    auto wallets = wm.listWallets();
    for (const auto& w : wallets) {
        m_walletCombo->addItem(w.name, w.id);
    }

    // Select current wallet
    for (int i = 0; i < m_walletCombo->count(); ++i) {
        if (m_walletCombo->itemData(i).toString() == wm.currentWalletId()) {
            m_walletCombo->setCurrentIndex(i);
            break;
        }
    }
    m_walletCombo->blockSignals(false);

    // Update address and balance
    if (wm.isUnlocked()) {
        QString addr = wm.primaryAddress();
        if (addr.length() > 20) {
            m_walletAddrLabel->setText(addr.left(10) + "..." + addr.right(8));
        } else {
            m_walletAddrLabel->setText(addr);
        }
        m_walletAddrLabel->setToolTip(addr + "\nClick to copy");

        // Balance comes from node if connected, otherwise show "offline"
        if (m_mode == NodeMode) {
            // Balance will be updated by NodeService signals
        } else {
            m_walletBalanceLabel->setText("Offline Wallet");
        }
    } else {
        m_walletAddrLabel->setText("(locked)");
        m_walletBalanceLabel->setText("");
    }
}

void MainWindow::setupMenuBar() {
    auto* fileMenu = menuBar()->addMenu("&File");

    // Wallet menu items
    auto* newWalletAct = fileMenu->addAction("&New Wallet...");
    auto* importWalletAct = fileMenu->addAction("&Import Wallet...");
    fileMenu->addSeparator();
    auto* settingsAct = fileMenu->addAction("&Settings...");
    fileMenu->addSeparator();
    auto* quitAct = fileMenu->addAction("&Quit");
    quitAct->setShortcut(QKeySequence("Ctrl+Q"));

    auto* viewMenu = menuBar()->addMenu("&View");
    auto* overviewAct = viewMenu->addAction("&Overview");
    overviewAct->setShortcut(QKeySequence("Ctrl+1"));
    auto* multiWalletAct = viewMenu->addAction("&Multi-Wallet");
    multiWalletAct->setShortcut(QKeySequence("Ctrl+2"));
    auto* sendAct = viewMenu->addAction("&Send");
    sendAct->setShortcut(QKeySequence("Ctrl+3"));
    auto* receiveAct = viewMenu->addAction("&Receive");
    receiveAct->setShortcut(QKeySequence("Ctrl+4"));
    auto* txAct = viewMenu->addAction("&Transactions");
    txAct->setShortcut(QKeySequence("Ctrl+5"));
    auto* miningAct = viewMenu->addAction("&Mining");
    miningAct->setShortcut(QKeySequence("Ctrl+6"));
    auto* networkAct = viewMenu->addAction("&Network");
    networkAct->setShortcut(QKeySequence("Ctrl+7"));
    auto* explorerAct = viewMenu->addAction("&Block Explorer");
    explorerAct->setShortcut(QKeySequence("Ctrl+8"));
    auto* consoleAct = viewMenu->addAction("&Console");
    consoleAct->setShortcut(QKeySequence("Ctrl+9"));
    auto* exchangeKeysAct = viewMenu->addAction("&Exchange Keys");
    exchangeKeysAct->setShortcut(QKeySequence("Ctrl+0"));

    auto* helpMenu = menuBar()->addMenu("&Help");
    auto* aboutAct = helpMenu->addAction("&About OmniBus-Qt");

    // Connections
    connect(newWalletAct, &QAction::triggered, this, [this]() {
        CreateWalletDialog dlg(this);
        if (dlg.exec() == QDialog::Accepted) {
            // Dialog already generated mnemonic internally
            auto& wm = WalletManager::instance();
            auto result = wm.importWallet(
                dlg.walletName(), dlg.password(), dlg.mnemonic(), dlg.passphrase());
            if (result.success) {
                setAppMode(WalletMode);
                refreshWalletToolbar();
                setWindowTitle(QString("OmniBus-Qt — %1").arg(wm.currentWalletName()));
                QMessageBox::information(this, "Wallet Created",
                    QString("Wallet '%1' created!\nAddress: %2")
                    .arg(dlg.walletName()).arg(wm.primaryAddress()));
            } else {
                QMessageBox::critical(this, "Error", result.error);
            }
        }
    });

    connect(importWalletAct, &QAction::triggered, this, [this]() {
        ImportWalletDialog dlg(this);
        if (dlg.exec() == QDialog::Accepted) {
            auto& wm = WalletManager::instance();
            auto result = wm.importWallet(dlg.walletName(), dlg.password(), dlg.mnemonic());
            if (result.success) {
                QMessageBox::information(this, "Wallet Imported",
                    QString("Wallet '%1' imported successfully!\nAddress: %2")
                    .arg(dlg.walletName())
                    .arg(wm.primaryAddress()));
                setAppMode(WalletMode);
                refreshWalletToolbar();
                setWindowTitle(QString("OmniBus-Qt — %1").arg(wm.currentWalletName()));
            } else {
                QMessageBox::critical(this, "Error", result.error);
            }
        }
    });

    connect(settingsAct, &QAction::triggered, this, [this]() {
        SettingsDialog dlg(this);
        if (dlg.exec() == QDialog::Accepted) {
            auto& svc = NodeService::instance();
            svc.stop();
            svc.start();
        }
    });

    connect(quitAct, &QAction::triggered, qApp, &QApplication::quit);

    connect(overviewAct, &QAction::triggered, this, [this]() { m_tabs->setCurrentIndex(0); });
    connect(multiWalletAct, &QAction::triggered, this, [this]() { m_tabs->setCurrentIndex(1); });
    connect(sendAct, &QAction::triggered, this, [this]() { m_tabs->setCurrentIndex(2); });
    connect(receiveAct, &QAction::triggered, this, [this]() { m_tabs->setCurrentIndex(3); });
    connect(txAct, &QAction::triggered, this, [this]() { m_tabs->setCurrentIndex(4); });
    connect(miningAct, &QAction::triggered, this, [this]() { m_tabs->setCurrentIndex(5); });
    connect(networkAct, &QAction::triggered, this, [this]() { m_tabs->setCurrentIndex(6); });
    connect(explorerAct, &QAction::triggered, this, [this]() { m_tabs->setCurrentIndex(7); });
    connect(consoleAct, &QAction::triggered, this, [this]() { m_tabs->setCurrentIndex(8); });
    connect(exchangeKeysAct, &QAction::triggered, this, [this]() { m_tabs->setCurrentIndex(9); });

    connect(aboutAct, &QAction::triggered, this, [this]() {
        AboutDialog dlg(this);
        dlg.exec();
    });
}

void MainWindow::setupTabs() {
    m_tabs = new QTabWidget;
    m_tabs->setDocumentMode(true);
    m_tabs->setTabPosition(QTabWidget::North);

    m_tabs->addTab(new OverviewTab,       "Overview");
    m_tabs->addTab(new MultiWalletTab,   "Multi-Wallet");
    m_tabs->addTab(new SendTab,          "Send");
    m_tabs->addTab(new ReceiveTab,       "Receive");
    m_tabs->addTab(new TransactionsTab,  "Transactions");
    m_tabs->addTab(new MiningTab,        "Mining");
    m_tabs->addTab(new NetworkTab,       "Network");
    m_tabs->addTab(new BlockExplorerTab, "Blocks");
    m_tabs->addTab(new ConsoleTab,       "Console");
    m_tabs->addTab(new ExchangeKeysTab,  "Exchange Keys");

    setCentralWidget(m_tabs);
}

void MainWindow::connectSignals() {
    auto& svc = NodeService::instance();

    connect(&svc, &NodeService::blockHeightChanged, m_statusBar, &StatusBar::setBlockHeight);
    connect(&svc, &NodeService::wsConnectionChanged, m_statusBar, &StatusBar::setWsConnected);

    connect(&svc, &NodeService::networkUpdated, this, [this](const NetworkInfo& info) {
        m_statusBar->setPeerCount(info.peerCount);
    });

    connect(&svc, &NodeService::newBlockReceived, this, [this](const BlockData& block) {
        QDateTime dt = QDateTime::fromMSecsSinceEpoch(block.timestamp);
        m_statusBar->setLastBlockTime(dt.toString("hh:mm:ss"));
    });

    connect(&svc, &NodeService::nodeOffline, this, [this]() {
        m_statusBar->showMessage("Node offline — check that omnibus-node is running on port 8332", 5000);
    });

    connect(&svc, &NodeService::nodeOnline, this, [this]() {
        m_statusBar->showMessage("Connected to node", 3000);
    });

    // Wallet balance update from node
    connect(&svc, &NodeService::walletUpdated, this, [this](const WalletInfo& info) {
        if (m_walletBalanceLabel && m_mode == NodeMode) {
            m_walletBalanceLabel->setText(info.balanceOMNI + " OMNI");
        }
    });

    // WalletManager signals
    auto& wm = WalletManager::instance();
    connect(&wm, &WalletManager::walletChanged, this, [this](const QString&, const QString& name) {
        setWindowTitle(QString("OmniBus-Qt — %1").arg(name));
        refreshWalletToolbar();
    });

    connect(&wm, &WalletManager::walletLocked, this, [this]() {
        refreshWalletToolbar();
        m_statusBar->showMessage("Wallet locked", 3000);
    });
}

void MainWindow::closeEvent(QCloseEvent* event) {
    QSettings settings("OmniBus", "OmniBus-Qt");
    settings.setValue("geometry", saveGeometry());
    settings.setValue("windowState", saveState());

    if (Settings::instance().minimizeToTray() && m_trayIcon->isVisible()) {
        hide();
        event->ignore();
    } else {
        VaultStorage::instance().lock();
        WalletManager::instance().lock();
        NodeService::instance().stop();
        event->accept();
    }
}

} // namespace omni

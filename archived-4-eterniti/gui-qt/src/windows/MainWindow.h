#pragma once

#include <QMainWindow>
#include <QTabWidget>
#include <QCloseEvent>
#include <QComboBox>
#include <QLabel>
#include <QToolBar>

namespace omni {

class StatusBar;
class TrayIcon;

class MainWindow : public QMainWindow {
    Q_OBJECT
public:
    enum AppMode { WalletMode, NodeMode };

    explicit MainWindow(AppMode mode, QWidget* parent = nullptr);

    void setAppMode(AppMode mode);
    AppMode appMode() const { return m_mode; }

protected:
    void closeEvent(QCloseEvent* event) override;

private:
    void setupMenuBar();
    void setupTabs();
    void setupWalletToolbar();
    void connectSignals();
    void refreshWalletToolbar();

    AppMode     m_mode;
    QTabWidget* m_tabs = nullptr;
    StatusBar*  m_statusBar = nullptr;
    TrayIcon*   m_trayIcon = nullptr;

    // Wallet toolbar
    QToolBar*   m_walletToolbar = nullptr;
    QComboBox*  m_walletCombo = nullptr;
    QLabel*     m_walletAddrLabel = nullptr;
    QLabel*     m_walletBalanceLabel = nullptr;
};

} // namespace omni

#include <QApplication>
#include <QFile>
#include <QLockFile>
#include <QStandardPaths>
#include <QDir>
#include <QMessageBox>
#include "windows/MainWindow.h"
#include "core/NodeService.h"
#include "core/Settings.h"
#include "core/WalletManager.h"
#include "dialogs/WelcomeDialog.h"
#include "dialogs/CreateWalletDialog.h"
#include "dialogs/ImportWalletDialog.h"
#include "dialogs/UnlockDialog.h"

int main(int argc, char *argv[])
{
    QApplication app(argc, argv);
    app.setApplicationName("OmniBus-Qt");
    app.setApplicationVersion("1.0.0");
    app.setOrganizationName("OmniBus");
    app.setOrganizationDomain("omnibus.ai");

    // Single-instance guard
    QString lockPath = QStandardPaths::writableLocation(QStandardPaths::TempLocation)
                       + "/omnibus-qt.lock";
    QLockFile lockFile(lockPath);
    if (!lockFile.tryLock(100)) {
        QMessageBox::warning(nullptr, "OmniBus-Qt",
            "Another instance of OmniBus-Qt is already running.");
        return 1;
    }

    // Load dark theme stylesheet
    QFile styleFile(":/stylesheets/dark-theme.qss");
    if (styleFile.open(QFile::ReadOnly | QFile::Text)) {
        app.setStyleSheet(QString::fromUtf8(styleFile.readAll()));
        styleFile.close();
    }

    // Initialize singletons
    omni::Settings::instance();
    auto& walletMgr = omni::WalletManager::instance();

    omni::MainWindow::AppMode appMode = omni::MainWindow::NodeMode;

    // ─── Startup flow ───
    if (!walletMgr.hasWallets()) {
        // First launch: show Welcome dialog
        omni::WelcomeDialog welcome;
        if (welcome.exec() != QDialog::Accepted) {
            return 0;
        }

        switch (welcome.userChoice()) {
        case omni::WelcomeDialog::CreateWallet: {
            omni::CreateWalletDialog createDlg;
            if (createDlg.exec() != QDialog::Accepted) return 0;

            // Dialog already generated the mnemonic internally
            // Now create the wallet with it
            auto result = walletMgr.importWallet(
                createDlg.walletName(),
                createDlg.password(),
                createDlg.mnemonic(),
                createDlg.passphrase());

            if (!result.success) {
                QMessageBox::critical(nullptr, "Error", result.error);
                return 1;
            }

            appMode = omni::MainWindow::WalletMode;
            break;
        }
        case omni::WelcomeDialog::ImportWallet: {
            omni::ImportWalletDialog importDlg;
            if (importDlg.exec() != QDialog::Accepted) return 0;

            auto result = walletMgr.importWallet(
                importDlg.walletName(),
                importDlg.password(),
                importDlg.mnemonic());

            if (!result.success) {
                QMessageBox::critical(nullptr, "Error", result.error);
                return 1;
            }

            appMode = omni::MainWindow::WalletMode;
            break;
        }
        case omni::WelcomeDialog::ConnectNode:
            appMode = omni::MainWindow::NodeMode;
            break;
        default:
            return 0;
        }
    } else {
        // Wallets exist: show Unlock dialog
        omni::UnlockDialog unlockDlg;
        QList<QPair<QString, QString>> walletList;
        for (const auto& w : walletMgr.listWallets())
            walletList.append({w.id, w.name});
        unlockDlg.setWallets(walletList);

        if (unlockDlg.exec() != QDialog::Accepted) {
            return 0;
        }

        if (!walletMgr.unlock(unlockDlg.selectedWalletId(), unlockDlg.password())) {
            QMessageBox::critical(nullptr, "Error",
                "Wrong password or corrupt wallet file.\nPlease restart and try again.");
            return 1;
        }
        appMode = omni::MainWindow::WalletMode;
    }

    // Start node service (for RPC/WS data, even in wallet mode)
    omni::NodeService::instance().start();

    // Show main window
    omni::MainWindow mainWindow(appMode);
    mainWindow.show();

    int ret = app.exec();
    lockFile.unlock();
    return ret;
}

#include "dialogs/WelcomeDialog.h"
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QPushButton>
#include <QFrame>

namespace omni {

WelcomeDialog::WelcomeDialog(QWidget* parent)
    : QDialog(parent)
{
    setWindowTitle("OmniBus Wallet");
    setMinimumSize(520, 480);
    setMaximumSize(520, 480);

    auto* layout = new QVBoxLayout(this);
    layout->setSpacing(16);
    layout->setContentsMargins(40, 30, 40, 30);

    // Logo / Title
    auto* titleLabel = new QLabel("OmniBus");
    titleLabel->setAlignment(Qt::AlignCenter);
    titleLabel->setStyleSheet("font-size: 32px; font-weight: bold; color: #00b3a4; margin-bottom: 4px;");
    layout->addWidget(titleLabel);

    auto* subtitleLabel = new QLabel("Post-Quantum Blockchain Wallet");
    subtitleLabel->setAlignment(Qt::AlignCenter);
    subtitleLabel->setStyleSheet("font-size: 14px; color: #8888aa; margin-bottom: 20px;");
    layout->addWidget(subtitleLabel);

    // Separator
    auto* sep = new QFrame;
    sep->setFrameShape(QFrame::HLine);
    sep->setStyleSheet("color: #2a2d44;");
    layout->addWidget(sep);

    layout->addSpacing(10);

    // Create Wallet button
    auto* createBtn = new QPushButton("  Create New Wallet");
    createBtn->setMinimumHeight(60);
    createBtn->setStyleSheet(
        "QPushButton { background: #4a90d9; color: white; font-size: 16px; font-weight: bold; "
        "border-radius: 8px; text-align: left; padding-left: 20px; }"
        "QPushButton:hover { background: #5aa0e9; }"
    );
    layout->addWidget(createBtn);

    auto* createDesc = new QLabel("Generate a new mnemonic phrase and create a fresh wallet");
    createDesc->setStyleSheet("color: #6666aa; font-size: 11px; margin-left: 20px; margin-bottom: 8px;");
    layout->addWidget(createDesc);

    // Import Wallet button
    auto* importBtn = new QPushButton("  Import Existing Wallet");
    importBtn->setMinimumHeight(60);
    importBtn->setStyleSheet(
        "QPushButton { background: #2a2d44; color: #e0e0f0; font-size: 16px; font-weight: bold; "
        "border-radius: 8px; border: 1px solid #4a90d9; text-align: left; padding-left: 20px; }"
        "QPushButton:hover { background: #3a3d54; }"
    );
    layout->addWidget(importBtn);

    auto* importDesc = new QLabel("Restore a wallet from a mnemonic phrase or backup file");
    importDesc->setStyleSheet("color: #6666aa; font-size: 11px; margin-left: 20px; margin-bottom: 8px;");
    layout->addWidget(importDesc);

    // Connect to Node button
    auto* connectBtn = new QPushButton("  Connect to Running Node");
    connectBtn->setMinimumHeight(60);
    connectBtn->setStyleSheet(
        "QPushButton { background: #1a1d2e; color: #8888aa; font-size: 16px; "
        "border-radius: 8px; border: 1px solid #3a3d54; text-align: left; padding-left: 20px; }"
        "QPushButton:hover { background: #2a2d44; color: #e0e0f0; }"
    );
    layout->addWidget(connectBtn);

    auto* connectDesc = new QLabel("Use the wallet from an existing OmniBus node (spectator mode)");
    connectDesc->setStyleSheet("color: #6666aa; font-size: 11px; margin-left: 20px;");
    layout->addWidget(connectDesc);

    layout->addStretch();

    // Version
    auto* versionLabel = new QLabel("OmniBus-Qt v1.0.0");
    versionLabel->setAlignment(Qt::AlignCenter);
    versionLabel->setStyleSheet("color: #444466; font-size: 10px;");
    layout->addWidget(versionLabel);

    // Connections
    connect(createBtn, &QPushButton::clicked, this, [this]() {
        m_choice = CreateWallet;
        accept();
    });
    connect(importBtn, &QPushButton::clicked, this, [this]() {
        m_choice = ImportWallet;
        accept();
    });
    connect(connectBtn, &QPushButton::clicked, this, [this]() {
        m_choice = ConnectNode;
        accept();
    });
}

} // namespace omni

#include "widgets/ReceiveTab.h"
#include "widgets/AddressLabel.h"
#include "widgets/QRCodeWidget.h"
#include "core/NodeService.h"
#include "core/WalletManager.h"

#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QFrame>
#include <QPushButton>
#include <QClipboard>
#include <QApplication>

namespace omni {

ReceiveTab::ReceiveTab(QWidget* parent)
    : QWidget(parent)
{
    setupUi();

    auto& svc = NodeService::instance();
    connect(&svc, &NodeService::walletUpdated, this, &ReceiveTab::onWalletUpdated);

    // Also listen for WalletManager changes (standalone wallet mode)
    auto& wm = WalletManager::instance();
    connect(&wm, &WalletManager::walletChanged, this, [this](const QString&, const QString&) {
        auto& wm2 = WalletManager::instance();
        if (wm2.isUnlocked()) {
            QString addr = wm2.primaryAddress();
            m_addressLabel->setAddress(addr);
            m_qrWidget->setData(addr);
        }
    });
    connect(&wm, &WalletManager::addressGenerated, this, [this](const WalletAddress& addr) {
        m_addressLabel->setAddress(addr.address);
        m_qrWidget->setData(addr.address);
    });

    // Initialize from WalletManager if already unlocked
    if (wm.isUnlocked()) {
        QString addr = wm.primaryAddress();
        if (!addr.isEmpty()) {
            m_addressLabel->setAddress(addr);
            m_qrWidget->setData(addr);
        }
    }
}

void ReceiveTab::setupUi() {
    auto* layout = new QVBoxLayout(this);
    layout->setContentsMargins(24, 24, 24, 24);
    layout->setSpacing(16);
    layout->setAlignment(Qt::AlignHCenter | Qt::AlignTop);

    auto* title = new QLabel("Receive OMNI");
    title->setObjectName("sectionTitle");
    title->setAlignment(Qt::AlignCenter);
    layout->addWidget(title);

    // QR Code
    auto* qrCard = new QFrame;
    qrCard->setObjectName("card");
    qrCard->setFixedSize(240, 240);
    auto* qrLayout = new QVBoxLayout(qrCard);
    qrLayout->setContentsMargins(16, 16, 16, 16);
    m_qrWidget = new QRCodeWidget;
    qrLayout->addWidget(m_qrWidget);
    layout->addWidget(qrCard, 0, Qt::AlignHCenter);

    // Address
    auto* addrCard = new QFrame;
    addrCard->setObjectName("cardHighlight");
    auto* addrLayout = new QVBoxLayout(addrCard);
    addrLayout->setContentsMargins(16, 12, 16, 12);

    auto* addrTitle = new QLabel("Your OmniBus Address");
    addrTitle->setObjectName("dimLabel");
    addrTitle->setAlignment(Qt::AlignCenter);

    m_addressLabel = new AddressLabel("Generating...");
    m_addressLabel->setAlignment(Qt::AlignCenter);
    m_addressLabel->setWordWrap(true);

    addrLayout->addWidget(addrTitle);
    addrLayout->addWidget(m_addressLabel);
    layout->addWidget(addrCard);

    // Copy button
    auto* copyBtn = new QPushButton("Copy Address");
    copyBtn->setObjectName("secondaryButton");
    copyBtn->setFixedWidth(200);
    connect(copyBtn, &QPushButton::clicked, this, [this]() {
        QApplication::clipboard()->setText(m_addressLabel->address());
    });
    layout->addWidget(copyBtn, 0, Qt::AlignHCenter);

    // Info
    m_infoLabel = new QLabel("Share this address to receive OMNI tokens.\n"
                              "Addresses start with 'ob1q' (Bech32 format).");
    m_infoLabel->setObjectName("dimLabel");
    m_infoLabel->setAlignment(Qt::AlignCenter);
    m_infoLabel->setWordWrap(true);
    layout->addWidget(m_infoLabel);

    layout->addStretch();
}

void ReceiveTab::onWalletUpdated(const WalletInfo& info) {
    // Only update from node if WalletManager doesn't have a local address
    auto& wm = WalletManager::instance();
    if (wm.isUnlocked() && !wm.primaryAddress().isEmpty()) {
        // Use local wallet address, not node address
        return;
    }
    m_addressLabel->setAddress(info.address);
    m_qrWidget->setData(info.address);
}

} // namespace omni

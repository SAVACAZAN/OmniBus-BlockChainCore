#include "widgets/MultiWalletTab.h"
#include "core/WalletManager.h"
#include "core/MultiChain.h"

#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QHeaderView>
#include <QClipboard>
#include <QApplication>
#include <QMessageBox>
#include <QGroupBox>
#include <QFrame>

namespace omni {

MultiWalletTab::MultiWalletTab(QWidget* parent)
    : QWidget(parent)
{
    setupUi();

    auto& wm = WalletManager::instance();
    connect(&wm, &WalletManager::walletChanged, this, [this](const QString&, const QString&) {
        populateTree();
    });

    if (wm.isUnlocked()) {
        populateTree();
    }
}

void MultiWalletTab::setupUi() {
    auto* layout = new QVBoxLayout(this);
    layout->setContentsMargins(16, 16, 16, 16);
    layout->setSpacing(12);

    // Header
    auto* headerLayout = new QHBoxLayout;

    auto* title = new QLabel("Multi-Chain Wallet");
    title->setStyleSheet("font-size: 20px; font-weight: bold; color: #00b3a4;");
    headerLayout->addWidget(title);

    headerLayout->addStretch();

    // Address count selector
    auto* countLabel = new QLabel("Addresses per chain:");
    countLabel->setStyleSheet("color: #8888aa;");
    headerLayout->addWidget(countLabel);

    m_addrCountCombo = new QComboBox;
    m_addrCountCombo->addItem("1 address", 1);
    m_addrCountCombo->addItem("3 addresses", 3);
    m_addrCountCombo->addItem("6 addresses", 6);
    m_addrCountCombo->setCurrentIndex(0);
    m_addrCountCombo->setMinimumWidth(140);
    headerLayout->addWidget(m_addrCountCombo);

    auto* regenBtn = new QPushButton("Generate");
    regenBtn->setStyleSheet("background: #4a90d9; color: white; font-weight: bold; padding: 6px 16px;");
    connect(regenBtn, &QPushButton::clicked, this, &MultiWalletTab::regenerateAddresses);
    headerLayout->addWidget(regenBtn);

    layout->addLayout(headerLayout);

    // Summary
    m_summaryLabel = new QLabel("Unlock a wallet to generate multi-chain addresses.");
    m_summaryLabel->setStyleSheet("color: #8888aa; font-size: 12px;");
    layout->addWidget(m_summaryLabel);

    // Tree widget
    m_tree = new QTreeWidget;
    m_tree->setHeaderLabels({"Chain / Domain", "Address Type", "Address", "Derivation Path", "Public Key"});
    m_tree->setAlternatingRowColors(true);
    m_tree->setRootIsDecorated(true);
    m_tree->setSelectionBehavior(QAbstractItemView::SelectRows);
    m_tree->setStyleSheet(
        "QTreeWidget { background: #11131f; alternate-background-color: #161829; "
        "color: #e0e0f0; border: 1px solid #2a2d44; font-size: 12px; }"
        "QTreeWidget::item { padding: 4px 0; }"
        "QTreeWidget::item:selected { background: #2a3d5a; }"
        "QHeaderView::section { background: #0d0f1a; color: #8888aa; "
        "border: 1px solid #2a2d44; padding: 6px; font-weight: bold; }"
    );

    // Column widths
    m_tree->header()->setStretchLastSection(true);
    m_tree->setColumnWidth(0, 180);
    m_tree->setColumnWidth(1, 130);
    m_tree->setColumnWidth(2, 380);
    m_tree->setColumnWidth(3, 180);

    connect(m_tree, &QTreeWidget::itemClicked, this, &MultiWalletTab::onItemClicked);

    layout->addWidget(m_tree, 1);

    // Detail panel
    auto* detailFrame = new QFrame;
    detailFrame->setStyleSheet("background: #0d0f1a; border: 1px solid #2a2d44; border-radius: 6px; padding: 8px;");
    auto* detailLayout = new QVBoxLayout(detailFrame);
    m_addressDetail = new QLabel("Click an address to see details. Click again to copy.");
    m_addressDetail->setStyleSheet("color: #7b61ff; font-family: 'Consolas', monospace; font-size: 13px;");
    m_addressDetail->setWordWrap(true);
    m_addressDetail->setTextInteractionFlags(Qt::TextSelectableByMouse);
    detailLayout->addWidget(m_addressDetail);
    layout->addWidget(detailFrame);
}

void MultiWalletTab::regenerateAddresses() {
    populateTree();
}

void MultiWalletTab::populateTree() {
    m_tree->clear();

    auto& wm = WalletManager::instance();
    if (!wm.isUnlocked()) {
        m_summaryLabel->setText("Wallet is locked. Unlock to generate addresses.");
        return;
    }

    int addrCount = m_addrCountCombo->currentData().toInt();

    QByteArray seed = wm.getSeed();
    if (seed.isEmpty()) {
        m_summaryLabel->setText("Cannot access wallet seed. Please unlock wallet.");
        return;
    }

    auto addresses = MultiChainWallet::deriveAll(seed, addrCount);

    // Group by chain
    struct ChainGroup {
        QString chain;
        QList<ChainAddress> addrs;
    };
    QMap<QString, QTreeWidgetItem*> chainNodes;
    QStringList chainOrder = {"OMNI", "BTC", "ETH", "BNB", "OP", "SOL", "ADA",
                               "DOT", "EGLD", "ATOM", "XLM", "XRP", "LTC", "DOGE", "BCH"};

    // Create chain parent nodes
    QMap<QString, QString> chainColors = {
        {"OMNI", "#00b3a4"}, {"BTC", "#f7931a"}, {"ETH", "#627eea"},
        {"BNB", "#f3ba2f"}, {"OP", "#ff0420"}, {"SOL", "#9945ff"},
        {"ADA", "#0033ad"}, {"DOT", "#e6007a"}, {"EGLD", "#23f7dd"},
        {"ATOM", "#2e3148"}, {"XLM", "#000000"}, {"XRP", "#23292f"},
        {"LTC", "#bfbbbb"}, {"DOGE", "#c3a634"}, {"BCH", "#8dc351"}
    };

    int totalAddresses = 0;
    int totalChains = 0;

    for (const auto& chainName : chainOrder) {
        QList<ChainAddress> chainAddrs;
        for (const auto& a : addresses) {
            if (a.chain == chainName) chainAddrs.append(a);
        }
        if (chainAddrs.isEmpty()) continue;

        totalChains++;

        // Group OMNI by domain
        if (chainName == "OMNI") {
            auto* omniNode = new QTreeWidgetItem(m_tree);
            omniNode->setText(0, "OMNI (5 PQ Domains)");
            omniNode->setForeground(0, QColor("#00b3a4"));
            QFont boldFont = omniNode->font(0);
            boldFont.setBold(true);
            boldFont.setPointSize(boldFont.pointSize() + 1);
            omniNode->setFont(0, boldFont);
            omniNode->setExpanded(true);

            QMap<QString, QTreeWidgetItem*> domainNodes;
            QStringList domainNames = {"omnibus.omni", "omnibus.love", "omnibus.food",
                                        "omnibus.rent", "omnibus.vacation"};
            QStringList domainAlgos = {"ML-DSA-87 + ML-KEM-768", "ML-DSA-87",
                                       "Falcon-512", "SLH-DSA", "Falcon-Light"};

            for (int d = 0; d < domainNames.size(); ++d) {
                auto* domNode = new QTreeWidgetItem(omniNode);
                domNode->setText(0, domainNames[d]);
                domNode->setText(1, domainAlgos[d]);
                domNode->setForeground(0, QColor("#00ffcc"));
                QFont df = domNode->font(0);
                df.setBold(true);
                domNode->setFont(0, df);
                domainNodes[domainNames[d]] = domNode;
            }

            for (const auto& a : chainAddrs) {
                auto* parentNode = domainNodes.value(a.domain, omniNode);
                auto* item = new QTreeWidgetItem(parentNode);
                item->setText(0, QString("#%1").arg(a.index));
                item->setText(1, a.addressType);
                item->setText(2, a.address);
                item->setText(3, a.derivationPath);
                item->setText(4, a.publicKeyHex.left(16) + "...");
                item->setToolTip(2, a.address);
                item->setToolTip(4, a.publicKeyHex);
                item->setForeground(2, QColor("#7b61ff"));
                item->setData(2, Qt::UserRole, a.address);
                item->setData(4, Qt::UserRole, a.publicKeyHex);
                totalAddresses++;
            }
        }
        // Group BTC by purpose
        else if (chainName == "BTC") {
            auto* btcNode = new QTreeWidgetItem(m_tree);
            btcNode->setText(0, "BTC (4 Address Types)");
            btcNode->setForeground(0, QColor("#f7931a"));
            QFont bf = btcNode->font(0);
            bf.setBold(true);
            bf.setPointSize(bf.pointSize() + 1);
            btcNode->setFont(0, bf);
            btcNode->setExpanded(true);

            QMap<QString, QTreeWidgetItem*> typeNodes;
            for (const auto& a : chainAddrs) {
                if (!typeNodes.contains(a.addressType)) {
                    auto* tNode = new QTreeWidgetItem(btcNode);
                    tNode->setText(0, a.addressType);
                    tNode->setText(1, QString("Purpose %1").arg(a.purpose));
                    QFont tf = tNode->font(0);
                    tf.setBold(true);
                    tNode->setFont(0, tf);
                    typeNodes[a.addressType] = tNode;
                }
                auto* item = new QTreeWidgetItem(typeNodes[a.addressType]);
                item->setText(0, QString("#%1").arg(a.index));
                item->setText(1, a.addressType);
                item->setText(2, a.address);
                item->setText(3, a.derivationPath);
                item->setText(4, a.publicKeyHex.left(16) + "...");
                item->setToolTip(2, a.address);
                item->setToolTip(4, a.publicKeyHex);
                item->setForeground(2, QColor("#f7931a"));
                item->setData(2, Qt::UserRole, a.address);
                item->setData(4, Qt::UserRole, a.publicKeyHex);
                totalAddresses++;
            }
        }
        // Other chains
        else {
            QString color = chainColors.value(chainName, "#e0e0f0");
            auto* chainNode = new QTreeWidgetItem(m_tree);
            chainNode->setText(0, chainName);
            chainNode->setText(1, chainAddrs.first().addressType);
            chainNode->setForeground(0, QColor(color));
            QFont cf = chainNode->font(0);
            cf.setBold(true);
            cf.setPointSize(cf.pointSize() + 1);
            chainNode->setFont(0, cf);

            for (const auto& a : chainAddrs) {
                auto* item = new QTreeWidgetItem(chainNode);
                item->setText(0, QString("#%1").arg(a.index));
                item->setText(1, a.addressType);
                item->setText(2, a.address);
                item->setText(3, a.derivationPath);
                item->setText(4, a.publicKeyHex.left(16) + "...");
                item->setToolTip(2, a.address);
                item->setToolTip(4, a.publicKeyHex);
                item->setForeground(2, QColor(color));
                item->setData(2, Qt::UserRole, a.address);
                item->setData(4, Qt::UserRole, a.publicKeyHex);
                totalAddresses++;
            }
        }
    }

    m_summaryLabel->setText(QString("Generated %1 addresses across %2 chains from same BIP-39 seed")
        .arg(totalAddresses).arg(totalChains));
    m_summaryLabel->setStyleSheet("color: #00b3a4; font-size: 12px; font-weight: bold;");
}

void MultiWalletTab::onItemClicked(QTreeWidgetItem* item, int column) {
    QString addr = item->data(2, Qt::UserRole).toString();
    QString pubkey = item->data(4, Qt::UserRole).toString();

    if (addr.isEmpty()) return;

    QString detail = QString("Address: %1\nPublic Key: %2\nPath: %3")
        .arg(addr).arg(pubkey).arg(item->text(3));
    m_addressDetail->setText(detail);

    // Copy address to clipboard on click
    QApplication::clipboard()->setText(addr);
    m_addressDetail->setText(detail + "\n\nAddress copied to clipboard!");
}

} // namespace omni

#include "widgets/OverviewTab.h"
#include "models/BlockTableModel.h"
#include "models/MempoolTableModel.h"
#include "core/NodeService.h"
#include "core/WalletManager.h"

#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QGridLayout>
#include <QGroupBox>
#include <QFrame>
#include <QHeaderView>

namespace omni {

OverviewTab::OverviewTab(QWidget* parent)
    : QWidget(parent)
{
    m_blockModel = new BlockTableModel(this);
    m_mempoolModel = new MempoolTableModel(this);
    setupUi();

    auto& svc = NodeService::instance();
    connect(&svc, &NodeService::walletUpdated, this, &OverviewTab::onWalletUpdated);
    connect(&svc, &NodeService::networkUpdated, this, &OverviewTab::onNetworkUpdated);
    connect(&svc, &NodeService::mempoolUpdated, this, &OverviewTab::onMempoolUpdated);
    connect(&svc, &NodeService::newBlockReceived, this, &OverviewTab::onNewBlock);
    connect(&svc, &NodeService::newTxReceived, this, &OverviewTab::onNewTx);
    connect(&svc, &NodeService::blockHeightChanged, this, &OverviewTab::onBlockHeightChanged);

    // Show local wallet info if available
    auto& wm = WalletManager::instance();
    connect(&wm, &WalletManager::walletChanged, this, [this](const QString&, const QString&) {
        auto& wm2 = WalletManager::instance();
        if (wm2.isUnlocked()) {
            m_addressLabel->setText(wm2.primaryAddress());
        }
    });
    if (wm.isUnlocked()) {
        m_addressLabel->setText(wm.primaryAddress());
        m_balanceLabel->setText("Local Wallet");
    }

    // Load initial recent blocks
    svc.rpc()->getBlocks(0, 8, [this](const QJsonValue& result, const QString& err) {
        if (err.isEmpty() && result.isObject()) {
            QJsonArray blocks = result.toObject()["blocks"].toArray();
            QList<BlockData> list;
            for (const auto& b : blocks)
                list.prepend(BlockData::fromJson(b.toObject()));
            m_blockModel->setBlocks(list);
        }
    });
}

void OverviewTab::setupUi() {
    auto* mainLayout = new QHBoxLayout(this);
    mainLayout->setSpacing(16);
    mainLayout->setContentsMargins(16, 16, 16, 16);

    // ── Left Column: Stats ──────────────────────────────────────────────
    auto* leftLayout = new QVBoxLayout;

    // Balance Card
    auto* balanceCard = new QFrame;
    balanceCard->setObjectName("cardHighlight");
    auto* balCardLayout = new QVBoxLayout(balanceCard);

    auto* balTitle = new QLabel("Wallet Balance");
    balTitle->setObjectName("sectionTitle");
    m_balanceLabel = new QLabel("0.0000 OMNI");
    m_balanceLabel->setObjectName("balanceLabel");
    m_balanceSatLabel = new QLabel("0 SAT");
    m_balanceSatLabel->setObjectName("dimLabel");
    m_addressLabel = new QLabel("--");
    m_addressLabel->setObjectName("dimLabel");
    m_addressLabel->setWordWrap(true);

    balCardLayout->addWidget(balTitle);
    balCardLayout->addWidget(m_balanceLabel);
    balCardLayout->addWidget(m_balanceSatLabel);
    balCardLayout->addWidget(m_addressLabel);

    // Node Stats Card
    auto* statsCard = new QFrame;
    statsCard->setObjectName("card");
    auto* statsLayout = new QGridLayout(statsCard);

    auto* statsTitle = new QLabel("Node Status");
    statsTitle->setObjectName("sectionTitle");
    statsLayout->addWidget(statsTitle, 0, 0, 1, 2);

    m_blockHeightLabel = new QLabel("0");
    m_difficultyLabel  = new QLabel("0");
    m_mempoolLabel     = new QLabel("0 txs");
    m_peerCountLabel   = new QLabel("0");
    m_nodeStatusLabel  = new QLabel("Connecting...");
    m_nodeStatusLabel->setObjectName("statusOrange");

    auto addStatRow = [&](int row, const QString& label, QLabel* value) {
        auto* lbl = new QLabel(label);
        lbl->setObjectName("dimLabel");
        statsLayout->addWidget(lbl, row, 0);
        statsLayout->addWidget(value, row, 1, Qt::AlignRight);
    };

    addStatRow(1, "Block Height:", m_blockHeightLabel);
    addStatRow(2, "Difficulty:", m_difficultyLabel);
    addStatRow(3, "Mempool:", m_mempoolLabel);
    addStatRow(4, "Peers:", m_peerCountLabel);
    addStatRow(5, "Status:", m_nodeStatusLabel);

    // Sync Progress
    m_syncProgress = new QProgressBar;
    m_syncProgress->setRange(0, 100);
    m_syncProgress->setValue(0);
    m_syncProgress->setTextVisible(true);
    m_syncProgress->setFormat("Syncing... %p%");

    leftLayout->addWidget(balanceCard);
    leftLayout->addWidget(statsCard);
    leftLayout->addWidget(m_syncProgress);
    leftLayout->addStretch();

    // ── Right Column: Recent Blocks + Mempool ───────────────────────────
    auto* rightLayout = new QVBoxLayout;

    auto* blocksTitle = new QLabel("Recent Blocks");
    blocksTitle->setObjectName("sectionTitle");
    m_recentBlocksView = new QTableView;
    m_recentBlocksView->setModel(m_blockModel);
    m_recentBlocksView->setAlternatingRowColors(true);
    m_recentBlocksView->setSelectionBehavior(QAbstractItemView::SelectRows);
    m_recentBlocksView->setSelectionMode(QAbstractItemView::SingleSelection);
    m_recentBlocksView->horizontalHeader()->setStretchLastSection(true);
    m_recentBlocksView->verticalHeader()->hide();
    m_recentBlocksView->setEditTriggers(QAbstractItemView::NoEditTriggers);

    auto* mempoolTitle = new QLabel("Pending Transactions");
    mempoolTitle->setObjectName("sectionTitle");
    m_mempoolView = new QTableView;
    m_mempoolView->setModel(m_mempoolModel);
    m_mempoolView->setAlternatingRowColors(true);
    m_mempoolView->setSelectionBehavior(QAbstractItemView::SelectRows);
    m_mempoolView->horizontalHeader()->setStretchLastSection(true);
    m_mempoolView->verticalHeader()->hide();
    m_mempoolView->setEditTriggers(QAbstractItemView::NoEditTriggers);
    m_mempoolView->setMaximumHeight(200);

    rightLayout->addWidget(blocksTitle);
    rightLayout->addWidget(m_recentBlocksView, 3);
    rightLayout->addWidget(mempoolTitle);
    rightLayout->addWidget(m_mempoolView, 1);

    mainLayout->addLayout(leftLayout, 2);
    mainLayout->addLayout(rightLayout, 3);
}

void OverviewTab::onWalletUpdated(const WalletInfo& info) {
    m_balanceLabel->setText(info.balanceOMNI + " OMNI");
    m_balanceSatLabel->setText(QString::number(info.balanceSAT) + " SAT");
    // Use local wallet address if available, otherwise node address
    auto& wm = WalletManager::instance();
    if (wm.isUnlocked() && !wm.primaryAddress().isEmpty()) {
        m_addressLabel->setText(wm.primaryAddress());
    } else {
        m_addressLabel->setText(info.address);
    }
}

void OverviewTab::onNetworkUpdated(const NetworkInfo& info) {
    m_blockHeightLabel->setText(QString::number(info.blockHeight));
    m_difficultyLabel->setText(QString::number(info.difficulty));
    m_mempoolLabel->setText(QString::number(info.mempoolSize) + " txs");
    m_peerCountLabel->setText(QString::number(info.peerCount));
    m_nodeStatusLabel->setText("Online");
    m_nodeStatusLabel->setObjectName("statusGreen");
    m_nodeStatusLabel->style()->unpolish(m_nodeStatusLabel);
    m_nodeStatusLabel->style()->polish(m_nodeStatusLabel);
}

void OverviewTab::onMempoolUpdated(const MempoolStats& stats) {
    m_mempoolLabel->setText(QString::number(stats.size) + " txs");
}

void OverviewTab::onNewBlock(const BlockData& block) {
    m_blockModel->prependBlock(block);
    m_blockHeightLabel->setText(QString::number(block.height));
}

void OverviewTab::onNewTx(const QString& txid, const QString& from, qint64 amountSat) {
    m_mempoolModel->addPendingTx(txid, from, amountSat);
}

void OverviewTab::onBlockHeightChanged(int height) {
    m_blockHeightLabel->setText(QString::number(height));
}

} // namespace omni

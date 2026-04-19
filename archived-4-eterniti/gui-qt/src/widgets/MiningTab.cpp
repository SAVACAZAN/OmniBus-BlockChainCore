#include "widgets/MiningTab.h"
#include "models/MinerTableModel.h"
#include "core/NodeService.h"

#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QGridLayout>
#include <QFrame>
#include <QPushButton>
#include <QHeaderView>
#include <QJsonArray>
#include <QTimer>

namespace omni {

MiningTab::MiningTab(QWidget* parent)
    : QWidget(parent)
{
    m_minerModel = new MinerTableModel(this);
    setupUi();
    refreshData();

    // Refresh every 30s
    auto* timer = new QTimer(this);
    connect(timer, &QTimer::timeout, this, &MiningTab::refreshData);
    timer->start(30000);

    connect(&NodeService::instance(), &NodeService::newBlockReceived, this, &MiningTab::refreshData);
}

void MiningTab::setupUi() {
    auto* layout = new QVBoxLayout(this);
    layout->setContentsMargins(16, 16, 16, 16);
    layout->setSpacing(12);

    auto* title = new QLabel("Mining & Pool Stats");
    title->setObjectName("sectionTitle");
    layout->addWidget(title);

    // Stats cards row
    auto* cardsLayout = new QHBoxLayout;

    auto makeCard = [](const QString& label, QLabel*& valueLabel) -> QFrame* {
        auto* card = new QFrame;
        card->setObjectName("card");
        auto* lay = new QVBoxLayout(card);
        auto* lbl = new QLabel(label);
        lbl->setObjectName("dimLabel");
        valueLabel = new QLabel("--");
        valueLabel->setStyleSheet("font-size: 20px; font-weight: bold; color: #4a90d9;");
        lay->addWidget(lbl);
        lay->addWidget(valueLabel);
        return card;
    };

    cardsLayout->addWidget(makeCard("Active Miners", m_totalMinersLabel));
    cardsLayout->addWidget(makeCard("Block Reward", m_blockRewardLabel));
    cardsLayout->addWidget(makeCard("Your Blocks", m_yourBlocksLabel));
    cardsLayout->addWidget(makeCard("Pool Hash", m_poolHashLabel));
    layout->addLayout(cardsLayout);

    // Miner table
    auto* tableTitle = new QLabel("Miner Leaderboard");
    tableTitle->setObjectName("sectionTitle");
    layout->addWidget(tableTitle);

    m_minerTable = new QTableView;
    m_minerTable->setModel(m_minerModel);
    m_minerTable->setAlternatingRowColors(true);
    m_minerTable->setSelectionBehavior(QAbstractItemView::SelectRows);
    m_minerTable->setSortingEnabled(true);
    m_minerTable->horizontalHeader()->setStretchLastSection(true);
    m_minerTable->verticalHeader()->hide();
    m_minerTable->setEditTriggers(QAbstractItemView::NoEditTriggers);
    layout->addWidget(m_minerTable);

    // Refresh button
    auto* refreshBtn = new QPushButton("Refresh");
    refreshBtn->setObjectName("secondaryButton");
    refreshBtn->setFixedWidth(120);
    connect(refreshBtn, &QPushButton::clicked, this, &MiningTab::refreshData);
    layout->addWidget(refreshBtn, 0, Qt::AlignRight);
}

void MiningTab::refreshData() {
    auto* rpc = NodeService::instance().rpc();

    rpc->getMinerStats([this](const QJsonValue& result, const QString& err) {
        if (err.isEmpty() && result.isObject()) {
            QJsonArray miners = result.toObject()["miners"].toArray();
            QList<MinerInfo> list;
            for (const auto& m : miners)
                list.append(MinerInfo::fromJson(m.toObject()));
            m_minerModel->setMiners(list);
            m_totalMinersLabel->setText(QString::number(list.size()));
        }
    });

    rpc->getPoolStats([this](const QJsonValue& result, const QString& err) {
        if (err.isEmpty() && result.isObject()) {
            auto obj = result.toObject();
            m_poolHashLabel->setText(obj["hashRate"].toString("--"));
        }
    });

    rpc->getMinerInfo([this](const QJsonValue& result, const QString& err) {
        if (err.isEmpty() && result.isObject()) {
            auto obj = result.toObject();
            m_yourBlocksLabel->setText(QString::number(obj["blocksMined"].toInt()));
            m_blockRewardLabel->setText(satToOmni(
                static_cast<qint64>(obj["blockRewardSAT"].toDouble())) + " OMNI");
        }
    });
}

} // namespace omni

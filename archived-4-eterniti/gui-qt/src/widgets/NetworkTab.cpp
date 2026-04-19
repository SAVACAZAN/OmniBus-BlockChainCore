#include "widgets/NetworkTab.h"
#include "models/PeerTableModel.h"
#include "core/NodeService.h"

#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QGridLayout>
#include <QFrame>
#include <QGroupBox>
#include <QPushButton>
#include <QHeaderView>
#include <QJsonArray>
#include <QTimer>

namespace omni {

NetworkTab::NetworkTab(QWidget* parent)
    : QWidget(parent)
{
    m_peerModel = new PeerTableModel(this);
    setupUi();

    auto& svc = NodeService::instance();
    connect(&svc, &NodeService::networkUpdated, this, &NetworkTab::onNetworkUpdated);

    refreshPeers();

    auto* timer = new QTimer(this);
    connect(timer, &QTimer::timeout, this, &NetworkTab::refreshPeers);
    timer->start(30000);
}

void NetworkTab::setupUi() {
    auto* layout = new QVBoxLayout(this);
    layout->setContentsMargins(16, 16, 16, 16);
    layout->setSpacing(12);

    // Network info grid
    auto* infoCard = new QFrame;
    infoCard->setObjectName("card");
    auto* grid = new QGridLayout(infoCard);
    grid->setSpacing(8);

    auto* title = new QLabel("Network Information");
    title->setObjectName("sectionTitle");
    grid->addWidget(title, 0, 0, 1, 4);

    auto addField = [&](int row, int col, const QString& label, QLabel*& value) {
        auto* lbl = new QLabel(label);
        lbl->setObjectName("dimLabel");
        value = new QLabel("--");
        grid->addWidget(lbl, row, col * 2);
        grid->addWidget(value, row, col * 2 + 1);
    };

    addField(1, 0, "Chain:", m_chainLabel);
    addField(1, 1, "Version:", m_versionLabel);
    addField(2, 0, "Block Height:", m_heightLabel);
    addField(2, 1, "Difficulty:", m_diffLabel);
    addField(3, 0, "Peers:", m_peerCountLabel);
    addField(3, 1, "Block Time:", m_blockTimeLabel);
    addField(4, 0, "Max Supply:", m_maxSupplyLabel);
    addField(4, 1, "Halving Every:", m_halvingLabel);

    layout->addWidget(infoCard);

    // Peers table
    auto* peersTitle = new QLabel("Connected Peers");
    peersTitle->setObjectName("sectionTitle");
    layout->addWidget(peersTitle);

    m_peerTable = new QTableView;
    m_peerTable->setModel(m_peerModel);
    m_peerTable->setAlternatingRowColors(true);
    m_peerTable->setSelectionBehavior(QAbstractItemView::SelectRows);
    m_peerTable->horizontalHeader()->setStretchLastSection(true);
    m_peerTable->verticalHeader()->hide();
    m_peerTable->setEditTriggers(QAbstractItemView::NoEditTriggers);
    layout->addWidget(m_peerTable);

    auto* refreshBtn = new QPushButton("Refresh Peers");
    refreshBtn->setObjectName("secondaryButton");
    refreshBtn->setFixedWidth(140);
    connect(refreshBtn, &QPushButton::clicked, this, &NetworkTab::refreshPeers);
    layout->addWidget(refreshBtn, 0, Qt::AlignRight);
}

void NetworkTab::onNetworkUpdated(const NetworkInfo& info) {
    m_chainLabel->setText(info.chain);
    m_versionLabel->setText(info.version);
    m_heightLabel->setText(QString::number(info.blockHeight));
    m_diffLabel->setText(QString::number(info.difficulty));
    m_peerCountLabel->setText(QString::number(info.peerCount));
    m_blockTimeLabel->setText(QString("%1 ms").arg(info.blockTimeMs));
    m_maxSupplyLabel->setText(satToOmni(info.maxSupply) + " OMNI");
    m_halvingLabel->setText(QString("%1 blocks").arg(info.halvingInterval));
}

void NetworkTab::refreshPeers() {
    NodeService::instance().rpc()->getPeers(
        [this](const QJsonValue& result, const QString& err) {
            if (err.isEmpty() && result.isObject()) {
                QJsonArray peers = result.toObject()["peers"].toArray();
                QList<PeerInfo> list;
                for (const auto& p : peers)
                    list.append(PeerInfo::fromJson(p.toObject()));
                m_peerModel->setPeers(list);
            }
        }
    );
}

} // namespace omni

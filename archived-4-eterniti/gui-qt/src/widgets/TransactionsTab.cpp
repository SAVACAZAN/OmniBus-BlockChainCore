#include "widgets/TransactionsTab.h"
#include "models/TransactionTableModel.h"
#include "core/NodeService.h"

#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QPushButton>
#include <QHeaderView>
#include <QJsonArray>

namespace omni {

TransactionsTab::TransactionsTab(QWidget* parent)
    : QWidget(parent)
{
    m_model = new TransactionTableModel(this);
    m_proxyModel = new QSortFilterProxyModel(this);
    m_proxyModel->setSourceModel(m_model);
    m_proxyModel->setFilterCaseSensitivity(Qt::CaseInsensitive);
    m_proxyModel->setFilterKeyColumn(-1); // search all columns

    setupUi();
    refreshTransactions();

    // Auto-refresh on new TX
    connect(&NodeService::instance(), &NodeService::newTxReceived, this, [this]() {
        refreshTransactions();
    });
    connect(&NodeService::instance(), &NodeService::newBlockReceived, this, [this]() {
        refreshTransactions();
    });
}

void TransactionsTab::setupUi() {
    auto* layout = new QVBoxLayout(this);
    layout->setContentsMargins(16, 16, 16, 16);
    layout->setSpacing(8);

    // Filter bar
    auto* filterBar = new QHBoxLayout;

    m_filterCombo = new QComboBox;
    m_filterCombo->addItems({"All", "Sent", "Received"});
    m_filterCombo->setFixedWidth(120);

    m_searchEdit = new QLineEdit;
    m_searchEdit->setPlaceholderText("Search by TxID or address...");

    auto* refreshBtn = new QPushButton("Refresh");
    refreshBtn->setObjectName("secondaryButton");
    refreshBtn->setFixedWidth(100);

    filterBar->addWidget(m_filterCombo);
    filterBar->addWidget(m_searchEdit, 1);
    filterBar->addWidget(refreshBtn);
    layout->addLayout(filterBar);

    // Table
    m_tableView = new QTableView;
    m_tableView->setModel(m_proxyModel);
    m_tableView->setAlternatingRowColors(true);
    m_tableView->setSelectionBehavior(QAbstractItemView::SelectRows);
    m_tableView->setSelectionMode(QAbstractItemView::SingleSelection);
    m_tableView->setSortingEnabled(true);
    m_tableView->horizontalHeader()->setStretchLastSection(true);
    m_tableView->verticalHeader()->hide();
    m_tableView->setEditTriggers(QAbstractItemView::NoEditTriggers);
    layout->addWidget(m_tableView);

    connect(m_filterCombo, &QComboBox::currentIndexChanged, this, &TransactionsTab::onFilterChanged);
    connect(m_searchEdit, &QLineEdit::textChanged, this, &TransactionsTab::onFilterChanged);
    connect(refreshBtn, &QPushButton::clicked, this, &TransactionsTab::refreshTransactions);
}

void TransactionsTab::onFilterChanged() {
    QString filter = m_filterCombo->currentText();
    QString search = m_searchEdit->text();

    m_proxyModel->setFilterFixedString(search);

    // Direction filter via custom proxy
    if (filter == "Sent") {
        m_proxyModel->setFilterKeyColumn(TransactionTableModel::ColDirection);
        m_proxyModel->setFilterFixedString("OUT");
    } else if (filter == "Received") {
        m_proxyModel->setFilterKeyColumn(TransactionTableModel::ColDirection);
        m_proxyModel->setFilterFixedString("IN");
    } else {
        m_proxyModel->setFilterKeyColumn(-1);
        m_proxyModel->setFilterFixedString(search);
    }
}

void TransactionsTab::refreshTransactions() {
    NodeService::instance().rpc()->listTransactions(100,
        [this](const QJsonValue& result, const QString& err) {
            if (err.isEmpty() && result.isObject()) {
                QJsonArray txArr = result.toObject()["transactions"].toArray();
                QList<TransactionData> txs;
                for (const auto& t : txArr)
                    txs.append(TransactionData::fromJson(t.toObject()));
                m_model->setTransactions(txs);
            }
        }
    );
}

} // namespace omni

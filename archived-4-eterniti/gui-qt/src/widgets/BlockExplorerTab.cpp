#include "widgets/BlockExplorerTab.h"
#include "models/BlockTableModel.h"
#include "core/NodeService.h"

#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QSplitter>
#include <QPushButton>
#include <QHeaderView>
#include <QJsonArray>
#include <QJsonDocument>
#include <QDateTime>

namespace omni {

BlockExplorerTab::BlockExplorerTab(QWidget* parent)
    : QWidget(parent)
{
    m_blockModel = new BlockTableModel(this);
    setupUi();

    // Load initial blocks
    NodeService::instance().rpc()->getBlockCount(
        [this](const QJsonValue& result, const QString& err) {
            if (err.isEmpty()) {
                auto obj = result.toObject();
                m_totalBlocks = obj.contains("blockCount") ? obj["blockCount"].toInt() : result.toInt();
                m_currentPage = 0;
                loadBlocks(qMax(0, m_totalBlocks - m_blocksPerPage));
            }
        }
    );

    connect(&NodeService::instance(), &NodeService::newBlockReceived, this, [this](const BlockData&) {
        m_totalBlocks++;
        if (m_currentPage == 0)
            loadBlocks(qMax(0, m_totalBlocks - m_blocksPerPage));
    });
}

void BlockExplorerTab::setupUi() {
    auto* layout = new QVBoxLayout(this);
    layout->setContentsMargins(16, 16, 16, 16);
    layout->setSpacing(8);

    // Search bar
    auto* searchBar = new QHBoxLayout;
    m_searchEdit = new QLineEdit;
    m_searchEdit->setPlaceholderText("Enter block height or hash...");
    auto* searchBtn = new QPushButton("Search");
    searchBtn->setFixedWidth(100);
    searchBar->addWidget(m_searchEdit, 1);
    searchBar->addWidget(searchBtn);
    layout->addLayout(searchBar);

    // Splitter: block table (top) + detail (bottom)
    auto* splitter = new QSplitter(Qt::Vertical);

    // Block table
    m_blockTable = new QTableView;
    m_blockTable->setModel(m_blockModel);
    m_blockTable->setAlternatingRowColors(true);
    m_blockTable->setSelectionBehavior(QAbstractItemView::SelectRows);
    m_blockTable->setSelectionMode(QAbstractItemView::SingleSelection);
    m_blockTable->horizontalHeader()->setStretchLastSection(true);
    m_blockTable->verticalHeader()->hide();
    m_blockTable->setEditTriggers(QAbstractItemView::NoEditTriggers);
    splitter->addWidget(m_blockTable);

    // Detail view
    m_detailView = new QTextEdit;
    m_detailView->setReadOnly(true);
    m_detailView->setPlaceholderText("Click a block to see details...");
    m_detailView->setStyleSheet("font-family: 'Consolas', monospace; font-size: 12px;");
    m_detailView->setMaximumHeight(200);
    splitter->addWidget(m_detailView);

    layout->addWidget(splitter, 1);

    // Pagination
    auto* pageBar = new QHBoxLayout;
    auto* prevBtn = new QPushButton("< Prev");
    prevBtn->setObjectName("secondaryButton");
    prevBtn->setFixedWidth(80);
    m_pageLabel = new QLabel("Page 1");
    m_pageLabel->setAlignment(Qt::AlignCenter);
    auto* nextBtn = new QPushButton("Next >");
    nextBtn->setObjectName("secondaryButton");
    nextBtn->setFixedWidth(80);
    pageBar->addWidget(prevBtn);
    pageBar->addStretch();
    pageBar->addWidget(m_pageLabel);
    pageBar->addStretch();
    pageBar->addWidget(nextBtn);
    layout->addLayout(pageBar);

    connect(searchBtn, &QPushButton::clicked, this, &BlockExplorerTab::onSearch);
    connect(m_searchEdit, &QLineEdit::returnPressed, this, &BlockExplorerTab::onSearch);
    connect(m_blockTable, &QTableView::clicked, this, &BlockExplorerTab::onBlockClicked);
    connect(prevBtn, &QPushButton::clicked, this, &BlockExplorerTab::onPrevPage);
    connect(nextBtn, &QPushButton::clicked, this, &BlockExplorerTab::onNextPage);
}

void BlockExplorerTab::onSearch() {
    QString query = m_searchEdit->text().trimmed();
    if (query.isEmpty()) return;

    bool isNum = false;
    int height = query.toInt(&isNum);

    if (isNum) {
        NodeService::instance().rpc()->getBlock(height,
            [this](const QJsonValue& result, const QString& err) {
                if (err.isEmpty() && result.isObject()) {
                    auto block = BlockData::fromJson(result.toObject());
                    QList<BlockData> list;
                    list.append(block);
                    m_blockModel->setBlocks(list);
                    m_detailView->setText(
                        QJsonDocument(result.toObject()).toJson(QJsonDocument::Indented));
                }
            }
        );
    } else {
        // Search by hash — try fetching blocks around recent heights
        m_detailView->setText("Hash search: looking up block...");
        // Use raw RPC if needed
        NodeService::instance().rpc()->rawRequest("getblock", QJsonArray{query},
            [this](const QJsonValue& result, const QString& err) {
                if (err.isEmpty() && result.isObject()) {
                    m_detailView->setText(
                        QJsonDocument(result.toObject()).toJson(QJsonDocument::Indented));
                } else {
                    m_detailView->setText("Block not found: " + err);
                }
            }
        );
    }
}

void BlockExplorerTab::loadBlocks(int fromHeight) {
    NodeService::instance().rpc()->getBlocks(fromHeight, m_blocksPerPage,
        [this, fromHeight](const QJsonValue& result, const QString& err) {
            if (err.isEmpty() && result.isObject()) {
                QJsonArray blocks = result.toObject()["blocks"].toArray();
                QList<BlockData> list;
                for (const auto& b : blocks)
                    list.append(BlockData::fromJson(b.toObject()));
                // Reverse so newest is first
                std::reverse(list.begin(), list.end());
                m_blockModel->setBlocks(list);

                int page = (m_totalBlocks > 0) ? (m_totalBlocks - fromHeight - 1) / m_blocksPerPage : 0;
                m_pageLabel->setText(QString("Page %1").arg(page + 1));
            }
        }
    );
}

void BlockExplorerTab::onBlockClicked(const QModelIndex& index) {
    if (!index.isValid()) return;
    const auto& block = m_blockModel->blockAt(index.row());

    NodeService::instance().rpc()->getBlock(block.height,
        [this](const QJsonValue& result, const QString& err) {
            if (err.isEmpty() && result.isObject()) {
                m_detailView->setText(
                    QJsonDocument(result.toObject()).toJson(QJsonDocument::Indented));
            }
        }
    );
}

void BlockExplorerTab::onNextPage() {
    int fromHeight = qMax(0, m_totalBlocks - (m_currentPage + 2) * m_blocksPerPage);
    m_currentPage++;
    loadBlocks(fromHeight);
}

void BlockExplorerTab::onPrevPage() {
    if (m_currentPage <= 0) return;
    m_currentPage--;
    int fromHeight = qMax(0, m_totalBlocks - (m_currentPage + 1) * m_blocksPerPage);
    loadBlocks(fromHeight);
}

} // namespace omni

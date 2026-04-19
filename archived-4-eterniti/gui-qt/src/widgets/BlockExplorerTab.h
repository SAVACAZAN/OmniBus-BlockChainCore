#pragma once

#include <QWidget>
#include <QLineEdit>
#include <QTableView>
#include <QLabel>
#include <QTextEdit>
#include "core/Types.h"

namespace omni {

class BlockTableModel;

class BlockExplorerTab : public QWidget {
    Q_OBJECT
public:
    explicit BlockExplorerTab(QWidget* parent = nullptr);

private slots:
    void onSearch();
    void loadBlocks(int fromHeight);
    void onBlockClicked(const QModelIndex& index);
    void onNextPage();
    void onPrevPage();

private:
    void setupUi();

    QLineEdit*       m_searchEdit;
    QTableView*      m_blockTable;
    BlockTableModel* m_blockModel;
    QTextEdit*       m_detailView;
    QLabel*          m_pageLabel;

    int m_currentPage = 0;
    int m_blocksPerPage = 20;
    int m_totalBlocks = 0;
};

} // namespace omni

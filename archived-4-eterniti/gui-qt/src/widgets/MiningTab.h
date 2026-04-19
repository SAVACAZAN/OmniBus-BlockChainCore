#pragma once

#include <QWidget>
#include <QLabel>
#include <QTableView>
#include "core/Types.h"

namespace omni {

class MinerTableModel;

class MiningTab : public QWidget {
    Q_OBJECT
public:
    explicit MiningTab(QWidget* parent = nullptr);

private slots:
    void refreshData();

private:
    void setupUi();

    QLabel* m_totalMinersLabel;
    QLabel* m_poolHashLabel;
    QLabel* m_blockRewardLabel;
    QLabel* m_yourBlocksLabel;
    QTableView* m_minerTable;
    MinerTableModel* m_minerModel;
};

} // namespace omni

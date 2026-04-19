#pragma once

#include <QWidget>
#include <QLabel>
#include <QTableView>
#include <QProgressBar>
#include "core/Types.h"

namespace omni {

class BlockTableModel;
class MempoolTableModel;

class OverviewTab : public QWidget {
    Q_OBJECT
public:
    explicit OverviewTab(QWidget* parent = nullptr);

public slots:
    void onWalletUpdated(const WalletInfo& info);
    void onNetworkUpdated(const NetworkInfo& info);
    void onMempoolUpdated(const MempoolStats& stats);
    void onNewBlock(const BlockData& block);
    void onNewTx(const QString& txid, const QString& from, qint64 amountSat);
    void onBlockHeightChanged(int height);

private:
    void setupUi();

    QLabel* m_balanceLabel;
    QLabel* m_balanceSatLabel;
    QLabel* m_addressLabel;
    QLabel* m_blockHeightLabel;
    QLabel* m_difficultyLabel;
    QLabel* m_mempoolLabel;
    QLabel* m_peerCountLabel;
    QLabel* m_nodeStatusLabel;
    QProgressBar* m_syncProgress;

    QTableView* m_recentBlocksView;
    QTableView* m_mempoolView;

    BlockTableModel* m_blockModel;
    MempoolTableModel* m_mempoolModel;
};

} // namespace omni

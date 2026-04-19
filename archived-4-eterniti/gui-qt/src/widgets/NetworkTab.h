#pragma once

#include <QWidget>
#include <QLabel>
#include <QTableView>
#include "core/Types.h"

namespace omni {

class PeerTableModel;

class NetworkTab : public QWidget {
    Q_OBJECT
public:
    explicit NetworkTab(QWidget* parent = nullptr);

public slots:
    void onNetworkUpdated(const NetworkInfo& info);

private slots:
    void refreshPeers();

private:
    void setupUi();

    QLabel* m_chainLabel;
    QLabel* m_versionLabel;
    QLabel* m_heightLabel;
    QLabel* m_diffLabel;
    QLabel* m_peerCountLabel;
    QLabel* m_blockTimeLabel;
    QLabel* m_maxSupplyLabel;
    QLabel* m_halvingLabel;

    QTableView* m_peerTable;
    PeerTableModel* m_peerModel;
};

} // namespace omni

#pragma once

#include <QAbstractTableModel>
#include <QList>
#include "core/Types.h"

namespace omni {

class PeerTableModel : public QAbstractTableModel {
    Q_OBJECT
public:
    enum Column { ColId, ColHost, ColPort, ColAlive, ColCount };

    explicit PeerTableModel(QObject* parent = nullptr);

    int rowCount(const QModelIndex& parent = {}) const override;
    int columnCount(const QModelIndex& parent = {}) const override;
    QVariant data(const QModelIndex& index, int role = Qt::DisplayRole) const override;
    QVariant headerData(int section, Qt::Orientation orientation, int role = Qt::DisplayRole) const override;

    void setPeers(const QList<PeerInfo>& peers);

private:
    QList<PeerInfo> m_peers;
};

} // namespace omni

#pragma once

#include <QAbstractTableModel>
#include <QList>
#include "core/Types.h"

namespace omni {

class MinerTableModel : public QAbstractTableModel {
    Q_OBJECT
public:
    enum Column { ColAddress, ColBlocksMined, ColTotalReward, ColBalance, ColCount };

    explicit MinerTableModel(QObject* parent = nullptr);

    int rowCount(const QModelIndex& parent = {}) const override;
    int columnCount(const QModelIndex& parent = {}) const override;
    QVariant data(const QModelIndex& index, int role = Qt::DisplayRole) const override;
    QVariant headerData(int section, Qt::Orientation orientation, int role = Qt::DisplayRole) const override;

    void setMiners(const QList<MinerInfo>& miners);

private:
    QList<MinerInfo> m_miners;
};

} // namespace omni

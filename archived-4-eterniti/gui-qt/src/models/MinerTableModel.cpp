#include "models/MinerTableModel.h"
#include <QColor>
#include <QFont>

namespace omni {

MinerTableModel::MinerTableModel(QObject* parent)
    : QAbstractTableModel(parent)
{
}

int MinerTableModel::rowCount(const QModelIndex&) const {
    return m_miners.size();
}

int MinerTableModel::columnCount(const QModelIndex&) const {
    return ColCount;
}

QVariant MinerTableModel::data(const QModelIndex& index, int role) const {
    if (!index.isValid() || index.row() >= m_miners.size())
        return {};

    const auto& m = m_miners[index.row()];

    if (role == Qt::DisplayRole) {
        switch (index.column()) {
        case ColAddress:      return m.miner.left(24) + "...";
        case ColBlocksMined:  return m.blocksMined;
        case ColTotalReward:  return satToOmni(m.totalRewardSAT) + " OMNI";
        case ColBalance:      return satToOmni(m.currentBalanceSAT) + " OMNI";
        }
    }
    else if (role == Qt::ForegroundRole) {
        if (index.column() == ColTotalReward || index.column() == ColBalance)
            return QColor("#00b3a4");
    }
    else if (role == Qt::FontRole) {
        if (index.column() == ColAddress) {
            QFont f;
            f.setFamily("Consolas");
            f.setPointSize(10);
            return f;
        }
    }
    else if (role == Qt::TextAlignmentRole) {
        if (index.column() != ColAddress)
            return int(Qt::AlignRight | Qt::AlignVCenter);
    }
    else if (role == Qt::ToolTipRole) {
        if (index.column() == ColAddress) return m.miner;
    }

    return {};
}

QVariant MinerTableModel::headerData(int section, Qt::Orientation orientation, int role) const {
    if (orientation != Qt::Horizontal || role != Qt::DisplayRole)
        return {};

    switch (section) {
    case ColAddress:      return "Miner Address";
    case ColBlocksMined:  return "Blocks";
    case ColTotalReward:  return "Total Reward";
    case ColBalance:      return "Balance";
    }
    return {};
}

void MinerTableModel::setMiners(const QList<MinerInfo>& miners) {
    beginResetModel();
    m_miners = miners;
    endResetModel();
}

} // namespace omni

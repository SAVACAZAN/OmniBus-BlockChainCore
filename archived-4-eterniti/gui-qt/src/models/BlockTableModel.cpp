#include "models/BlockTableModel.h"
#include <QDateTime>
#include <QColor>
#include <QFont>

namespace omni {

BlockTableModel::BlockTableModel(QObject* parent)
    : QAbstractTableModel(parent)
{
}

int BlockTableModel::rowCount(const QModelIndex&) const {
    return m_blocks.size();
}

int BlockTableModel::columnCount(const QModelIndex&) const {
    return ColCount;
}

QVariant BlockTableModel::data(const QModelIndex& index, int role) const {
    if (!index.isValid() || index.row() >= m_blocks.size())
        return {};

    const auto& b = m_blocks[index.row()];

    if (role == Qt::DisplayRole) {
        switch (index.column()) {
        case ColHeight:    return b.height;
        case ColHash:      return b.hash.left(16) + "...";
        case ColMiner:     return b.miner.isEmpty() ? "Genesis" : b.miner.left(20) + "...";
        case ColTxCount:   return b.txCount;
        case ColReward:    return satToOmni(b.rewardSAT) + " OMNI";
        case ColTimestamp: {
            QDateTime dt = QDateTime::fromMSecsSinceEpoch(b.timestamp);
            return dt.toString("yyyy-MM-dd hh:mm:ss");
        }
        }
    }
    else if (role == Qt::ForegroundRole) {
        if (index.column() == ColHeight) return QColor("#4a90d9");
        if (index.column() == ColReward) return QColor("#00b3a4");
    }
    else if (role == Qt::FontRole) {
        if (index.column() == ColHash || index.column() == ColMiner) {
            QFont f;
            f.setFamily("Consolas");
            f.setPointSize(10);
            return f;
        }
    }
    else if (role == Qt::TextAlignmentRole) {
        if (index.column() == ColHeight || index.column() == ColTxCount || index.column() == ColReward)
            return int(Qt::AlignRight | Qt::AlignVCenter);
    }
    else if (role == Qt::ToolTipRole) {
        if (index.column() == ColHash) return b.hash;
        if (index.column() == ColMiner) return b.miner;
    }

    return {};
}

QVariant BlockTableModel::headerData(int section, Qt::Orientation orientation, int role) const {
    if (orientation != Qt::Horizontal || role != Qt::DisplayRole)
        return {};

    switch (section) {
    case ColHeight:    return "Height";
    case ColHash:      return "Hash";
    case ColMiner:     return "Miner";
    case ColTxCount:   return "TXs";
    case ColReward:    return "Reward";
    case ColTimestamp: return "Time";
    }
    return {};
}

void BlockTableModel::setBlocks(const QList<BlockData>& blocks) {
    beginResetModel();
    m_blocks = blocks;
    endResetModel();
}

void BlockTableModel::prependBlock(const BlockData& block) {
    beginInsertRows({}, 0, 0);
    m_blocks.prepend(block);
    endInsertRows();
}

void BlockTableModel::clear() {
    beginResetModel();
    m_blocks.clear();
    endResetModel();
}

} // namespace omni

#include "models/MempoolTableModel.h"
#include <QColor>
#include <QFont>

namespace omni {

MempoolTableModel::MempoolTableModel(QObject* parent)
    : QAbstractTableModel(parent)
{
}

int MempoolTableModel::rowCount(const QModelIndex&) const {
    return m_txs.size();
}

int MempoolTableModel::columnCount(const QModelIndex&) const {
    return ColCount;
}

QVariant MempoolTableModel::data(const QModelIndex& index, int role) const {
    if (!index.isValid() || index.row() >= m_txs.size())
        return {};

    const auto& tx = m_txs[index.row()];

    if (role == Qt::DisplayRole) {
        switch (index.column()) {
        case ColTxId:   return tx.txid.left(16) + "...";
        case ColFrom:   return tx.from.left(20) + "...";
        case ColAmount: return satToOmni(tx.amountSat) + " OMNI";
        }
    }
    else if (role == Qt::ForegroundRole) {
        if (index.column() == ColAmount) return QColor("#ff9500");
    }
    else if (role == Qt::FontRole) {
        if (index.column() == ColTxId || index.column() == ColFrom) {
            QFont f;
            f.setFamily("Consolas");
            f.setPointSize(10);
            return f;
        }
    }
    else if (role == Qt::ToolTipRole) {
        if (index.column() == ColTxId) return tx.txid;
        if (index.column() == ColFrom) return tx.from;
    }

    return {};
}

QVariant MempoolTableModel::headerData(int section, Qt::Orientation orientation, int role) const {
    if (orientation != Qt::Horizontal || role != Qt::DisplayRole)
        return {};

    switch (section) {
    case ColTxId:   return "TxID";
    case ColFrom:   return "From";
    case ColAmount: return "Amount";
    }
    return {};
}

void MempoolTableModel::addPendingTx(const QString& txid, const QString& from, qint64 amountSat) {
    beginInsertRows({}, 0, 0);
    m_txs.prepend({txid, from, amountSat});
    // Keep max 50 entries
    if (m_txs.size() > 50) {
        beginRemoveRows({}, 50, m_txs.size() - 1);
        while (m_txs.size() > 50) m_txs.removeLast();
        endRemoveRows();
    }
    endInsertRows();
}

void MempoolTableModel::clear() {
    beginResetModel();
    m_txs.clear();
    endResetModel();
}

} // namespace omni

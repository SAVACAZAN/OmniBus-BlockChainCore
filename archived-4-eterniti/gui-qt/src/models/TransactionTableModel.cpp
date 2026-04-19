#include "models/TransactionTableModel.h"
#include <QColor>
#include <QFont>

namespace omni {

TransactionTableModel::TransactionTableModel(QObject* parent)
    : QAbstractTableModel(parent)
{
}

int TransactionTableModel::rowCount(const QModelIndex&) const {
    return m_transactions.size();
}

int TransactionTableModel::columnCount(const QModelIndex&) const {
    return ColCount;
}

QVariant TransactionTableModel::data(const QModelIndex& index, int role) const {
    if (!index.isValid() || index.row() >= m_transactions.size())
        return {};

    const auto& tx = m_transactions[index.row()];

    if (role == Qt::DisplayRole) {
        switch (index.column()) {
        case ColDirection:    return tx.direction == "received" ? "IN" : "OUT";
        case ColTxId:         return tx.txid.left(16) + "...";
        case ColFrom:         return tx.from.left(20) + "...";
        case ColTo:           return tx.to.left(20) + "...";
        case ColAmount:       return satToOmni(tx.amountSAT) + " OMNI";
        case ColFee:          return satToOmni(tx.feeSAT);
        case ColConfirmations: return tx.confirmations;
        case ColStatus:       return tx.status;
        }
    }
    else if (role == Qt::ForegroundRole) {
        if (index.column() == ColDirection || index.column() == ColAmount) {
            return tx.direction == "received" ? QColor("#00b3a4") : QColor("#ff9500");
        }
        if (index.column() == ColStatus) {
            return tx.status == "confirmed" ? QColor("#00b3a4") : QColor("#ff9500");
        }
    }
    else if (role == Qt::FontRole) {
        if (index.column() == ColTxId || index.column() == ColFrom || index.column() == ColTo) {
            QFont f;
            f.setFamily("Consolas");
            f.setPointSize(10);
            return f;
        }
    }
    else if (role == Qt::TextAlignmentRole) {
        if (index.column() == ColAmount || index.column() == ColFee || index.column() == ColConfirmations)
            return int(Qt::AlignRight | Qt::AlignVCenter);
    }
    else if (role == Qt::ToolTipRole) {
        if (index.column() == ColTxId) return tx.txid;
        if (index.column() == ColFrom) return tx.from;
        if (index.column() == ColTo)   return tx.to;
    }

    return {};
}

QVariant TransactionTableModel::headerData(int section, Qt::Orientation orientation, int role) const {
    if (orientation != Qt::Horizontal || role != Qt::DisplayRole)
        return {};

    switch (section) {
    case ColDirection:     return "Dir";
    case ColTxId:          return "TxID";
    case ColFrom:          return "From";
    case ColTo:            return "To";
    case ColAmount:        return "Amount";
    case ColFee:           return "Fee";
    case ColConfirmations: return "Conf";
    case ColStatus:        return "Status";
    }
    return {};
}

void TransactionTableModel::setTransactions(const QList<TransactionData>& txs) {
    beginResetModel();
    m_transactions = txs;
    endResetModel();
}

void TransactionTableModel::addTransaction(const TransactionData& tx) {
    beginInsertRows({}, 0, 0);
    m_transactions.prepend(tx);
    endInsertRows();
}

void TransactionTableModel::clear() {
    beginResetModel();
    m_transactions.clear();
    endResetModel();
}

} // namespace omni

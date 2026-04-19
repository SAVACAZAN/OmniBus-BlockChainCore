#pragma once

#include <QAbstractTableModel>
#include <QList>
#include "core/Types.h"

namespace omni {

class TransactionTableModel : public QAbstractTableModel {
    Q_OBJECT
public:
    enum Column { ColDirection, ColTxId, ColFrom, ColTo, ColAmount, ColFee, ColConfirmations, ColStatus, ColCount };

    explicit TransactionTableModel(QObject* parent = nullptr);

    int rowCount(const QModelIndex& parent = {}) const override;
    int columnCount(const QModelIndex& parent = {}) const override;
    QVariant data(const QModelIndex& index, int role = Qt::DisplayRole) const override;
    QVariant headerData(int section, Qt::Orientation orientation, int role = Qt::DisplayRole) const override;

    void setTransactions(const QList<TransactionData>& txs);
    void addTransaction(const TransactionData& tx);
    void clear();

private:
    QList<TransactionData> m_transactions;
};

} // namespace omni

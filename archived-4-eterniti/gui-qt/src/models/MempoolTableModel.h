#pragma once

#include <QAbstractTableModel>
#include <QList>
#include "core/Types.h"

namespace omni {

class MempoolTableModel : public QAbstractTableModel {
    Q_OBJECT
public:
    enum Column { ColTxId, ColFrom, ColAmount, ColCount };

    explicit MempoolTableModel(QObject* parent = nullptr);

    int rowCount(const QModelIndex& parent = {}) const override;
    int columnCount(const QModelIndex& parent = {}) const override;
    QVariant data(const QModelIndex& index, int role = Qt::DisplayRole) const override;
    QVariant headerData(int section, Qt::Orientation orientation, int role = Qt::DisplayRole) const override;

    void addPendingTx(const QString& txid, const QString& from, qint64 amountSat);
    void clear();

private:
    struct PendingTx {
        QString txid;
        QString from;
        qint64 amountSat;
    };
    QList<PendingTx> m_txs;
};

} // namespace omni

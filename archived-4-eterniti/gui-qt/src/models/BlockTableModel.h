#pragma once

#include <QAbstractTableModel>
#include <QList>
#include "core/Types.h"

namespace omni {

class BlockTableModel : public QAbstractTableModel {
    Q_OBJECT
public:
    enum Column { ColHeight, ColHash, ColMiner, ColTxCount, ColReward, ColTimestamp, ColCount };

    explicit BlockTableModel(QObject* parent = nullptr);

    int rowCount(const QModelIndex& parent = {}) const override;
    int columnCount(const QModelIndex& parent = {}) const override;
    QVariant data(const QModelIndex& index, int role = Qt::DisplayRole) const override;
    QVariant headerData(int section, Qt::Orientation orientation, int role = Qt::DisplayRole) const override;

    void setBlocks(const QList<BlockData>& blocks);
    void prependBlock(const BlockData& block);
    void clear();

    const BlockData& blockAt(int row) const { return m_blocks[row]; }

private:
    QList<BlockData> m_blocks;
};

} // namespace omni

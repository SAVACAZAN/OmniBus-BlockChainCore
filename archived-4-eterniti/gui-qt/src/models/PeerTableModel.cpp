#include "models/PeerTableModel.h"
#include <QColor>
#include <QFont>

namespace omni {

PeerTableModel::PeerTableModel(QObject* parent)
    : QAbstractTableModel(parent)
{
}

int PeerTableModel::rowCount(const QModelIndex&) const {
    return m_peers.size();
}

int PeerTableModel::columnCount(const QModelIndex&) const {
    return ColCount;
}

QVariant PeerTableModel::data(const QModelIndex& index, int role) const {
    if (!index.isValid() || index.row() >= m_peers.size())
        return {};

    const auto& p = m_peers[index.row()];

    if (role == Qt::DisplayRole) {
        switch (index.column()) {
        case ColId:    return p.id.left(12) + "...";
        case ColHost:  return p.host;
        case ColPort:  return p.port;
        case ColAlive: return p.alive ? "Online" : "Offline";
        }
    }
    else if (role == Qt::ForegroundRole) {
        if (index.column() == ColAlive) {
            return p.alive ? QColor("#00b3a4") : QColor("#d94a4a");
        }
    }
    else if (role == Qt::FontRole) {
        if (index.column() == ColId) {
            QFont f;
            f.setFamily("Consolas");
            f.setPointSize(10);
            return f;
        }
    }
    else if (role == Qt::ToolTipRole) {
        if (index.column() == ColId) return p.id;
    }

    return {};
}

QVariant PeerTableModel::headerData(int section, Qt::Orientation orientation, int role) const {
    if (orientation != Qt::Horizontal || role != Qt::DisplayRole)
        return {};

    switch (section) {
    case ColId:    return "Peer ID";
    case ColHost:  return "Host";
    case ColPort:  return "Port";
    case ColAlive: return "Status";
    }
    return {};
}

void PeerTableModel::setPeers(const QList<PeerInfo>& peers) {
    beginResetModel();
    m_peers = peers;
    endResetModel();
}

} // namespace omni

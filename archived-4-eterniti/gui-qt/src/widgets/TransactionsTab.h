#pragma once

#include <QWidget>
#include <QTableView>
#include <QLineEdit>
#include <QComboBox>
#include <QSortFilterProxyModel>

namespace omni {

class TransactionTableModel;

class TransactionsTab : public QWidget {
    Q_OBJECT
public:
    explicit TransactionsTab(QWidget* parent = nullptr);

private slots:
    void onFilterChanged();
    void refreshTransactions();

private:
    void setupUi();

    QTableView*             m_tableView;
    QLineEdit*              m_searchEdit;
    QComboBox*              m_filterCombo;
    TransactionTableModel*  m_model;
    QSortFilterProxyModel*  m_proxyModel;
};

} // namespace omni

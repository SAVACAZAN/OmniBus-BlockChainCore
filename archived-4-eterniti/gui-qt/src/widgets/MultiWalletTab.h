#pragma once

#include <QWidget>
#include <QTreeWidget>
#include <QLabel>
#include <QComboBox>
#include <QPushButton>

namespace omni {

class MultiWalletTab : public QWidget {
    Q_OBJECT
public:
    explicit MultiWalletTab(QWidget* parent = nullptr);

private slots:
    void regenerateAddresses();
    void onItemClicked(QTreeWidgetItem* item, int column);

private:
    void setupUi();
    void populateTree();

    QTreeWidget* m_tree = nullptr;
    QLabel* m_summaryLabel = nullptr;
    QLabel* m_addressDetail = nullptr;
    QComboBox* m_addrCountCombo = nullptr;
};

} // namespace omni

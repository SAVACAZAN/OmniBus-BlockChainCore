// ============================================================
//  ExchangeKeysTab.h  —  Multi-exchange API key manager
//
//  Sub-tabs: LCX | Kraken | Coinbase
//  Each sub-tab: list of API keys + Add/Edit/Delete + status
//  All keys stored in SuperVault (DPAPI encrypted vault.dat)
// ============================================================
#pragma once

#include <QWidget>
#include <QTabWidget>
#include <QTableWidget>
#include <QPushButton>
#include <QStackedWidget>
#include <QLineEdit>
#include <QLabel>
#include <QComboBox>

#include "core/VaultStorage.h"

namespace omni {

// ─── Single exchange panel (used inside each sub-tab) ────────
class ExchangePanel : public QWidget {
    Q_OBJECT
public:
    explicit ExchangePanel(VaultExchange exchange, QWidget* parent = nullptr);

    void refreshTable();

private slots:
    void onAddKey();
    void onEditKey();
    void onDeleteKey();
    void onSelectionChanged();

private:
    void setupUi();
    int selectedSlot() const;

    VaultExchange   m_exchange;
    QTableWidget*   m_table;
    QPushButton*    m_addBtn;
    QPushButton*    m_editBtn;
    QPushButton*    m_deleteBtn;
    QLabel*         m_countLabel;
};

// ─── Main tab with sub-tabs + lock/unlock ────────────────────
class ExchangeKeysTab : public QWidget {
    Q_OBJECT
public:
    explicit ExchangeKeysTab(QWidget* parent = nullptr);

public slots:
    void refreshAll();

private slots:
    void onLockUnlock();

private:
    void setupUi();
    void updateLockState();

    QTabWidget*      m_subTabs;
    ExchangePanel*   m_panels[VAULT_EXCHANGE_COUNT];
    QPushButton*     m_lockBtn;
    QLabel*          m_statusLabel;
    QLabel*          m_vaultPathLabel;
};

} // namespace omni

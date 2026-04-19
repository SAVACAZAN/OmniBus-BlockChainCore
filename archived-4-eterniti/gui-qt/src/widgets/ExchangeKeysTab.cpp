// ============================================================
//  ExchangeKeysTab.cpp  —  Multi-exchange API key manager UI
// ============================================================

#include "widgets/ExchangeKeysTab.h"

#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QHeaderView>
#include <QMessageBox>
#include <QInputDialog>
#include <QFormLayout>
#include <QDialogButtonBox>
#include <QDialog>
#include <QGroupBox>
#include <QFont>

namespace omni {

// ═══════════════════════════════════════════════════════════════
//  ExchangePanel — one panel per exchange
// ═══════════════════════════════════════════════════════════════

ExchangePanel::ExchangePanel(VaultExchange exchange, QWidget* parent)
    : QWidget(parent), m_exchange(exchange)
{
    setupUi();
    refreshTable();
}

void ExchangePanel::setupUi() {
    auto* layout = new QVBoxLayout(this);
    layout->setContentsMargins(8, 8, 8, 8);

    // Header
    auto* headerLayout = new QHBoxLayout;
    auto* titleLabel = new QLabel(
        QString("<b style='color:#7b61ff; font-size:14px;'>%1 — API Keys</b>")
        .arg(VaultStorage::exchangeName(m_exchange)));
    headerLayout->addWidget(titleLabel);
    headerLayout->addStretch();

    m_countLabel = new QLabel;
    m_countLabel->setStyleSheet("color: #8888aa; font-size: 11px;");
    headerLayout->addWidget(m_countLabel);

    layout->addLayout(headerLayout);

    // Table
    m_table = new QTableWidget(0, 4);
    m_table->setHorizontalHeaderLabels({"Name", "API Key", "Status", "Slot"});
    m_table->setSelectionBehavior(QAbstractItemView::SelectRows);
    m_table->setSelectionMode(QAbstractItemView::SingleSelection);
    m_table->setEditTriggers(QAbstractItemView::NoEditTriggers);
    m_table->setAlternatingRowColors(true);
    m_table->verticalHeader()->setVisible(false);
    m_table->horizontalHeader()->setStretchLastSection(false);
    m_table->horizontalHeader()->setSectionResizeMode(0, QHeaderView::Stretch);
    m_table->horizontalHeader()->setSectionResizeMode(1, QHeaderView::Stretch);
    m_table->horizontalHeader()->setSectionResizeMode(2, QHeaderView::ResizeToContents);
    m_table->horizontalHeader()->setSectionResizeMode(3, QHeaderView::ResizeToContents);
    m_table->setColumnHidden(3, true); // slot index hidden
    m_table->setStyleSheet(
        "QTableWidget { background: #0d0f1a; color: #e0e0f0; gridline-color: #2a2d44; }"
        "QTableWidget::item:selected { background: #2a1f5e; }"
        "QHeaderView::section { background: #1a1d2e; color: #8888aa; border: 1px solid #2a2d44; padding: 4px; }"
    );
    layout->addWidget(m_table);

    // Buttons
    auto* btnLayout = new QHBoxLayout;

    m_addBtn = new QPushButton("+ Add Key");
    m_addBtn->setStyleSheet(
        "QPushButton { background: #00b3a4; color: white; border-radius: 4px; padding: 6px 16px; font-weight: bold; }"
        "QPushButton:hover { background: #00cdb8; }"
    );

    m_editBtn = new QPushButton("Edit");
    m_editBtn->setEnabled(false);
    m_editBtn->setStyleSheet(
        "QPushButton { background: #3a3d54; color: #e0e0f0; border-radius: 4px; padding: 6px 16px; }"
        "QPushButton:hover { background: #4a4d64; }"
        "QPushButton:disabled { color: #555; }"
    );

    m_deleteBtn = new QPushButton("Delete");
    m_deleteBtn->setEnabled(false);
    m_deleteBtn->setStyleSheet(
        "QPushButton { background: #3a3d54; color: #ff5555; border-radius: 4px; padding: 6px 16px; }"
        "QPushButton:hover { background: #4a4d64; }"
        "QPushButton:disabled { color: #555; }"
    );

    btnLayout->addWidget(m_addBtn);
    btnLayout->addWidget(m_editBtn);
    btnLayout->addWidget(m_deleteBtn);
    btnLayout->addStretch();

    layout->addLayout(btnLayout);

    // Connections
    connect(m_addBtn,    &QPushButton::clicked, this, &ExchangePanel::onAddKey);
    connect(m_editBtn,   &QPushButton::clicked, this, &ExchangePanel::onEditKey);
    connect(m_deleteBtn, &QPushButton::clicked, this, &ExchangePanel::onDeleteKey);
    connect(m_table,     &QTableWidget::itemSelectionChanged, this, &ExchangePanel::onSelectionChanged);
}

void ExchangePanel::refreshTable() {
    auto& vault = VaultStorage::instance();
    m_table->setRowCount(0);

    int count = 0;
    for (int s = 0; s < VAULT_MAX_KEYS; ++s) {
        auto key = vault.getKey(m_exchange, s);
        if (!key.inUse) continue;

        int row = m_table->rowCount();
        m_table->insertRow(row);

        m_table->setItem(row, 0, new QTableWidgetItem(key.name));

        // Mask the API key — show first 6 + last 4 chars
        QString masked = key.apiKey;
        if (masked.length() > 12) {
            masked = masked.left(6) + "..." + masked.right(4);
        }
        m_table->setItem(row, 1, new QTableWidgetItem(masked));

        auto* statusItem = new QTableWidgetItem(VaultStorage::statusName(static_cast<VaultKeyStatus>(key.status)));
        switch (key.status) {
        case KEY_STATUS_PAID:
            statusItem->setForeground(QColor("#00b3a4"));
            break;
        case KEY_STATUS_NOTPAID:
            statusItem->setForeground(QColor("#ff5555"));
            break;
        default:
            statusItem->setForeground(QColor("#ccaa00"));
            break;
        }
        m_table->setItem(row, 2, statusItem);

        // Hidden slot index
        m_table->setItem(row, 3, new QTableWidgetItem(QString::number(s)));

        ++count;
    }

    m_countLabel->setText(QString("%1 / %2 keys").arg(count).arg(VAULT_MAX_KEYS));
    m_addBtn->setEnabled(count < VAULT_MAX_KEYS && vault.isLoaded());
    onSelectionChanged();
}

int ExchangePanel::selectedSlot() const {
    auto sel = m_table->selectionModel()->selectedRows();
    if (sel.isEmpty()) return -1;
    return m_table->item(sel.first().row(), 3)->text().toInt();
}

void ExchangePanel::onSelectionChanged() {
    bool hasSel = !m_table->selectionModel()->selectedRows().isEmpty();
    m_editBtn->setEnabled(hasSel);
    m_deleteBtn->setEnabled(hasSel);
}

// ─── Add Key Dialog ──────────────────────────────────────────

static bool showKeyDialog(QWidget* parent, const QString& title,
                          QString& name, QString& apiKey, QString& apiSecret,
                          VaultKeyStatus& status, bool editing = false)
{
    QDialog dlg(parent);
    dlg.setWindowTitle(title);
    dlg.setMinimumWidth(500);
    dlg.setStyleSheet(
        "QDialog { background: #12141f; }"
        "QLabel { color: #e0e0f0; }"
        "QLineEdit { background: #1a1d2e; color: #e0e0f0; border: 1px solid #3a3d54; "
        "  border-radius: 4px; padding: 6px; font-family: 'Consolas', monospace; }"
        "QComboBox { background: #1a1d2e; color: #e0e0f0; border: 1px solid #3a3d54; "
        "  border-radius: 4px; padding: 4px; }"
    );

    auto* form = new QFormLayout;

    auto* nameEdit = new QLineEdit(name);
    nameEdit->setPlaceholderText("e.g. Main Trading Key");

    auto* keyEdit = new QLineEdit(apiKey);
    keyEdit->setPlaceholderText("API Key from exchange");

    auto* secretEdit = new QLineEdit(apiSecret);
    secretEdit->setPlaceholderText("API Secret from exchange");
    secretEdit->setEchoMode(QLineEdit::Password);

    // Toggle secret visibility
    auto* showSecretBtn = new QPushButton("Show");
    showSecretBtn->setFixedWidth(60);
    showSecretBtn->setStyleSheet(
        "QPushButton { background: #2a2d44; color: #8888aa; border-radius: 3px; padding: 4px; }"
        "QPushButton:hover { background: #3a3d54; }"
    );
    QObject::connect(showSecretBtn, &QPushButton::clicked, [secretEdit, showSecretBtn]() {
        if (secretEdit->echoMode() == QLineEdit::Password) {
            secretEdit->setEchoMode(QLineEdit::Normal);
            showSecretBtn->setText("Hide");
        } else {
            secretEdit->setEchoMode(QLineEdit::Password);
            showSecretBtn->setText("Show");
        }
    });

    auto* secretLayout = new QHBoxLayout;
    secretLayout->addWidget(secretEdit);
    secretLayout->addWidget(showSecretBtn);

    auto* statusCombo = new QComboBox;
    statusCombo->addItem("Free",     KEY_STATUS_FREE);
    statusCombo->addItem("Paid",     KEY_STATUS_PAID);
    statusCombo->addItem("Not Paid", KEY_STATUS_NOTPAID);
    statusCombo->setCurrentIndex(static_cast<int>(status));

    form->addRow("Name:", nameEdit);
    form->addRow("API Key:", keyEdit);
    form->addRow("API Secret:", secretLayout);
    form->addRow("Status:", statusCombo);

    auto* buttons = new QDialogButtonBox(QDialogButtonBox::Ok | QDialogButtonBox::Cancel);
    buttons->setStyleSheet(
        "QPushButton { background: #7b61ff; color: white; border-radius: 4px; padding: 6px 20px; }"
        "QPushButton:hover { background: #8b71ff; }"
    );

    auto* mainLayout = new QVBoxLayout(&dlg);
    mainLayout->addLayout(form);
    mainLayout->addSpacing(10);
    mainLayout->addWidget(buttons);

    QObject::connect(buttons, &QDialogButtonBox::accepted, &dlg, &QDialog::accept);
    QObject::connect(buttons, &QDialogButtonBox::rejected, &dlg, &QDialog::reject);

    if (dlg.exec() != QDialog::Accepted) return false;

    name      = nameEdit->text().trimmed();
    apiKey    = keyEdit->text().trimmed();
    apiSecret = secretEdit->text().trimmed();
    status    = static_cast<VaultKeyStatus>(statusCombo->currentData().toInt());

    if (name.isEmpty() || apiKey.isEmpty()) {
        QMessageBox::warning(parent, "Error", "Name and API Key are required.");
        return false;
    }

    return true;
}

void ExchangePanel::onAddKey() {
    auto& vault = VaultStorage::instance();
    if (!vault.isLoaded()) {
        QMessageBox::warning(this, "Vault Locked", "Unlock the vault first.");
        return;
    }

    QString name, apiKey, apiSecret;
    VaultKeyStatus status = KEY_STATUS_FREE;
    QString title = QString("Add %1 API Key").arg(VaultStorage::exchangeName(m_exchange));

    if (showKeyDialog(this, title, name, apiKey, apiSecret, status)) {
        if (vault.addKey(m_exchange, name, apiKey, apiSecret, status)) {
            refreshTable();
        } else {
            QMessageBox::critical(this, "Error", "Failed to save key. Vault may be full (max 8 keys).");
        }
    }
}

void ExchangePanel::onEditKey() {
    int slot = selectedSlot();
    if (slot < 0) return;

    auto& vault = VaultStorage::instance();
    auto key = vault.getKey(m_exchange, slot);
    if (!key.inUse) return;

    QString name = key.name, apiKey = key.apiKey, apiSecret = key.apiSecret;
    VaultKeyStatus status = static_cast<VaultKeyStatus>(key.status);
    QString title = QString("Edit %1 API Key").arg(VaultStorage::exchangeName(m_exchange));

    if (showKeyDialog(this, title, name, apiKey, apiSecret, status, true)) {
        if (vault.updateKey(m_exchange, slot, name, apiKey, apiSecret, status)) {
            refreshTable();
        } else {
            QMessageBox::critical(this, "Error", "Failed to update key.");
        }
    }
}

void ExchangePanel::onDeleteKey() {
    int slot = selectedSlot();
    if (slot < 0) return;

    auto& vault = VaultStorage::instance();
    auto key = vault.getKey(m_exchange, slot);

    auto reply = QMessageBox::question(this, "Delete Key",
        QString("Delete key '%1' from %2?\n\nThis cannot be undone.")
        .arg(key.name).arg(VaultStorage::exchangeName(m_exchange)),
        QMessageBox::Yes | QMessageBox::No, QMessageBox::No);

    if (reply == QMessageBox::Yes) {
        vault.deleteKey(m_exchange, slot);
        refreshTable();
    }
}

// ═══════════════════════════════════════════════════════════════
//  ExchangeKeysTab — main tab with sub-tabs + lock/unlock
// ═══════════════════════════════════════════════════════════════

ExchangeKeysTab::ExchangeKeysTab(QWidget* parent)
    : QWidget(parent)
{
    setupUi();

    // Initialize vault on tab creation
    auto& vault = VaultStorage::instance();
    if (!vault.isLoaded()) {
        vault.init();
    }

    updateLockState();
    refreshAll();
}

void ExchangeKeysTab::setupUi() {
    auto* layout = new QVBoxLayout(this);
    layout->setContentsMargins(12, 12, 12, 12);

    // ── Top bar: title + lock button + status ────────────────
    auto* topBar = new QHBoxLayout;

    auto* titleLabel = new QLabel(
        "<span style='color:#e0e0f0; font-size:16px; font-weight:bold;'>"
        "Exchange API Keys</span>"
        "<span style='color:#8888aa; font-size:11px;'>"
        "  —  SuperVault DPAPI Encrypted</span>");
    topBar->addWidget(titleLabel);
    topBar->addStretch();

    m_statusLabel = new QLabel;
    m_statusLabel->setStyleSheet("font-size: 12px; padding: 0 8px;");
    topBar->addWidget(m_statusLabel);

    m_lockBtn = new QPushButton;
    m_lockBtn->setFixedSize(100, 30);
    m_lockBtn->setStyleSheet(
        "QPushButton { border-radius: 4px; font-weight: bold; padding: 4px 12px; }"
        "QPushButton[locked=\"true\"]  { background: #ff5555; color: white; }"
        "QPushButton[locked=\"false\"] { background: #00b3a4; color: white; }"
    );
    topBar->addWidget(m_lockBtn);

    layout->addLayout(topBar);

    // ── Vault file path label ────────────────────────────────
    m_vaultPathLabel = new QLabel;
    m_vaultPathLabel->setStyleSheet("color: #555; font-size: 10px; font-family: 'Consolas', monospace;");
    m_vaultPathLabel->setText(QString("Vault: %1").arg(VaultStorage::vaultFilePath()));
    layout->addWidget(m_vaultPathLabel);

    layout->addSpacing(8);

    // ── Sub-tabs per exchange ────────────────────────────────
    m_subTabs = new QTabWidget;
    m_subTabs->setTabPosition(QTabWidget::West);
    m_subTabs->setStyleSheet(
        "QTabWidget::pane { border: 1px solid #2a2d44; background: #12141f; }"
        "QTabBar::tab { background: #1a1d2e; color: #8888aa; padding: 10px 16px; "
        "  border: 1px solid #2a2d44; margin-bottom: 2px; }"
        "QTabBar::tab:selected { background: #2a1f5e; color: #7b61ff; font-weight: bold; }"
        "QTabBar::tab:hover { background: #2a2d44; }"
    );

    // Exchange colors for tab icons (via colored text)
    struct ExInfo { VaultExchange ex; QString color; };
    ExInfo exchanges[] = {
        {VAULT_LCX,      "#00b3a4"},
        {VAULT_KRAKEN,   "#7b61ff"},
        {VAULT_COINBASE, "#0052ff"},
    };

    for (const auto& info : exchanges) {
        auto* panel = new ExchangePanel(info.ex);
        m_panels[info.ex] = panel;
        m_subTabs->addTab(panel, VaultStorage::exchangeName(info.ex));
    }

    layout->addWidget(m_subTabs, 1);

    // Connections
    connect(m_lockBtn, &QPushButton::clicked, this, &ExchangeKeysTab::onLockUnlock);
}

void ExchangeKeysTab::updateLockState() {
    auto& vault = VaultStorage::instance();
    bool loaded = vault.isLoaded();

    if (loaded) {
        m_lockBtn->setText("Lock");
        m_lockBtn->setProperty("locked", false);
        m_statusLabel->setText("<span style='color:#00b3a4;'>Unlocked</span>");
    } else {
        m_lockBtn->setText("Unlock");
        m_lockBtn->setProperty("locked", true);
        m_statusLabel->setText("<span style='color:#ff5555;'>Locked</span>");
    }
    // Force style refresh
    m_lockBtn->style()->unpolish(m_lockBtn);
    m_lockBtn->style()->polish(m_lockBtn);

    // Enable/disable sub-tabs
    m_subTabs->setEnabled(loaded);
}

void ExchangeKeysTab::onLockUnlock() {
    auto& vault = VaultStorage::instance();

    if (vault.isLoaded()) {
        // Lock
        vault.lock();
    } else {
        // Unlock (re-init from disk)
        if (!vault.init()) {
            QMessageBox::warning(this, "Vault Error",
                "Could not unlock vault.\n\n"
                "The vault file may not exist yet — add a key to create it.\n"
                "File: " + VaultStorage::vaultFilePath());
            // Still mark as loaded for first-time use (empty vault)
        }
    }

    updateLockState();
    refreshAll();
}

void ExchangeKeysTab::refreshAll() {
    for (int i = 0; i < VAULT_EXCHANGE_COUNT; ++i) {
        if (m_panels[i]) m_panels[i]->refreshTable();
    }
}

} // namespace omni

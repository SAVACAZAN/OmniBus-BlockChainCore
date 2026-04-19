#include "dialogs/UnlockDialog.h"
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QPushButton>

namespace omni {

UnlockDialog::UnlockDialog(QWidget* parent)
    : QDialog(parent)
{
    setWindowTitle("Unlock Wallet");
    setMinimumSize(400, 300);
    setMaximumSize(400, 300);

    auto* layout = new QVBoxLayout(this);
    layout->setSpacing(12);
    layout->setContentsMargins(30, 25, 30, 25);

    auto* title = new QLabel("Unlock Wallet");
    title->setStyleSheet("font-size: 20px; font-weight: bold; color: #00b3a4;");
    layout->addWidget(title);

    // Wallet selector
    layout->addWidget(new QLabel("Select Wallet:"));
    m_walletCombo = new QComboBox;
    m_walletCombo->setMinimumHeight(36);
    layout->addWidget(m_walletCombo);

    // Password
    layout->addWidget(new QLabel("Password:"));
    m_passwordEdit = new QLineEdit;
    m_passwordEdit->setEchoMode(QLineEdit::Password);
    m_passwordEdit->setPlaceholderText("Enter wallet password");
    m_passwordEdit->setMinimumHeight(36);
    layout->addWidget(m_passwordEdit);

    m_statusLabel = new QLabel;
    m_statusLabel->setStyleSheet("color: #d94a4a; font-size: 11px;");
    layout->addWidget(m_statusLabel);

    layout->addStretch();

    // Buttons
    auto* btnLayout = new QHBoxLayout;
    auto* cancelBtn = new QPushButton("Cancel");
    cancelBtn->setMinimumHeight(40);
    auto* unlockBtn = new QPushButton("Unlock");
    unlockBtn->setMinimumHeight(40);
    unlockBtn->setStyleSheet("background: #4a90d9; color: white; font-weight: bold;");
    btnLayout->addWidget(cancelBtn);
    btnLayout->addStretch();
    btnLayout->addWidget(unlockBtn);
    layout->addLayout(btnLayout);

    connect(cancelBtn, &QPushButton::clicked, this, &QDialog::reject);
    connect(unlockBtn, &QPushButton::clicked, this, [this]() {
        if (m_passwordEdit->text().isEmpty()) {
            m_statusLabel->setText("Please enter your password.");
            return;
        }
        accept();
    });

    // Enter key triggers unlock
    connect(m_passwordEdit, &QLineEdit::returnPressed, unlockBtn, &QPushButton::click);
}

void UnlockDialog::setWallets(const QList<QPair<QString, QString>>& wallets) {
    m_walletCombo->clear();
    for (const auto& w : wallets) {
        m_walletCombo->addItem(w.second, w.first); // display name, data = id
    }
}

QString UnlockDialog::selectedWalletId() const {
    return m_walletCombo ? m_walletCombo->currentData().toString() : "";
}

QString UnlockDialog::password() const {
    return m_passwordEdit ? m_passwordEdit->text() : "";
}

} // namespace omni

#include "dialogs/ImportWalletDialog.h"
#include "core/LocalCrypto.h"
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QPushButton>
#include <QFileDialog>
#include <QMessageBox>

namespace omni {

ImportWalletDialog::ImportWalletDialog(QWidget* parent)
    : QDialog(parent)
{
    setWindowTitle("Import Wallet");
    setMinimumSize(500, 500);

    auto* layout = new QVBoxLayout(this);
    layout->setSpacing(12);
    layout->setContentsMargins(30, 20, 30, 20);

    auto* title = new QLabel("Import Existing Wallet");
    title->setStyleSheet("font-size: 20px; font-weight: bold; color: #00b3a4;");
    layout->addWidget(title);

    auto* desc = new QLabel("Enter your mnemonic phrase to restore your wallet.");
    desc->setStyleSheet("color: #8888aa; margin-bottom: 10px;");
    desc->setWordWrap(true);
    layout->addWidget(desc);

    // Mnemonic
    layout->addWidget(new QLabel("Mnemonic Phrase (12 or 24 words):"));
    m_mnemonicEdit = new QTextEdit;
    m_mnemonicEdit->setPlaceholderText("Enter your mnemonic words separated by spaces...");
    m_mnemonicEdit->setMinimumHeight(80);
    m_mnemonicEdit->setMaximumHeight(100);
    m_mnemonicEdit->setStyleSheet(
        "QTextEdit { background: #1a1d2e; color: #00b3a4; font-size: 14px; "
        "font-family: 'Consolas', monospace; padding: 10px; border-radius: 6px; }"
    );
    layout->addWidget(m_mnemonicEdit);

    // Load from file button
    auto* loadFileBtn = new QPushButton("Load from File...");
    loadFileBtn->setMaximumWidth(160);
    connect(loadFileBtn, &QPushButton::clicked, this, [this]() {
        QString path = QFileDialog::getOpenFileName(this, "Load Mnemonic", "", "Text Files (*.txt);;All Files (*)");
        if (path.isEmpty()) return;
        QFile f(path);
        if (f.open(QIODevice::ReadOnly)) {
            m_mnemonicEdit->setText(QString::fromUtf8(f.readAll()).trimmed());
        }
    });
    layout->addWidget(loadFileBtn);

    m_statusLabel = new QLabel;
    m_statusLabel->setStyleSheet("font-size: 11px;");
    layout->addWidget(m_statusLabel);

    // Validate on text change
    connect(m_mnemonicEdit, &QTextEdit::textChanged, this, [this]() {
        QString text = m_mnemonicEdit->toPlainText().simplified();
        QStringList words = text.split(' ', Qt::SkipEmptyParts);
        if (words.size() == 12 || words.size() == 24) {
            if (crypto::validateMnemonic(text)) {
                m_statusLabel->setText(QString("Valid mnemonic (%1 words)").arg(words.size()));
                m_statusLabel->setStyleSheet("color: #00b3a4; font-size: 11px;");
            } else {
                m_statusLabel->setText("Invalid mnemonic (checksum failed)");
                m_statusLabel->setStyleSheet("color: #d94a4a; font-size: 11px;");
            }
        } else {
            m_statusLabel->setText(QString("%1 words (need 12 or 24)").arg(words.size()));
            m_statusLabel->setStyleSheet("color: #8888aa; font-size: 11px;");
        }
    });

    // Wallet name
    layout->addSpacing(8);
    layout->addWidget(new QLabel("Wallet Name:"));
    m_nameEdit = new QLineEdit;
    m_nameEdit->setPlaceholderText("Imported Wallet");
    m_nameEdit->setMinimumHeight(36);
    layout->addWidget(m_nameEdit);

    // Password
    layout->addWidget(new QLabel("Encryption Password (min 8 characters):"));
    m_passwordEdit = new QLineEdit;
    m_passwordEdit->setEchoMode(QLineEdit::Password);
    m_passwordEdit->setPlaceholderText("Enter password");
    m_passwordEdit->setMinimumHeight(36);
    layout->addWidget(m_passwordEdit);

    // Confirm
    layout->addWidget(new QLabel("Confirm Password:"));
    m_confirmEdit = new QLineEdit;
    m_confirmEdit->setEchoMode(QLineEdit::Password);
    m_confirmEdit->setPlaceholderText("Confirm password");
    m_confirmEdit->setMinimumHeight(36);
    layout->addWidget(m_confirmEdit);

    layout->addStretch();

    // Buttons
    auto* btnLayout = new QHBoxLayout;
    auto* cancelBtn = new QPushButton("Cancel");
    cancelBtn->setMinimumHeight(40);
    auto* importBtn = new QPushButton("Import Wallet");
    importBtn->setMinimumHeight(40);
    importBtn->setStyleSheet("background: #4a90d9; color: white; font-weight: bold;");
    btnLayout->addWidget(cancelBtn);
    btnLayout->addStretch();
    btnLayout->addWidget(importBtn);
    layout->addLayout(btnLayout);

    connect(cancelBtn, &QPushButton::clicked, this, &QDialog::reject);
    connect(importBtn, &QPushButton::clicked, this, [this]() {
        QString mn = m_mnemonicEdit->toPlainText().simplified();
        if (!crypto::validateMnemonic(mn)) {
            QMessageBox::warning(this, "Error", "Invalid mnemonic phrase.");
            return;
        }
        if (m_nameEdit->text().trimmed().isEmpty()) {
            QMessageBox::warning(this, "Error", "Please enter a wallet name.");
            return;
        }
        if (m_passwordEdit->text().size() < 8) {
            QMessageBox::warning(this, "Error", "Password must be at least 8 characters.");
            return;
        }
        if (m_passwordEdit->text() != m_confirmEdit->text()) {
            QMessageBox::warning(this, "Error", "Passwords do not match.");
            return;
        }
        accept();
    });
}

QString ImportWalletDialog::walletName() const { return m_nameEdit ? m_nameEdit->text().trimmed() : ""; }
QString ImportWalletDialog::password() const { return m_passwordEdit ? m_passwordEdit->text() : ""; }
QString ImportWalletDialog::mnemonic() const { return m_mnemonicEdit ? m_mnemonicEdit->toPlainText().simplified() : ""; }

} // namespace omni

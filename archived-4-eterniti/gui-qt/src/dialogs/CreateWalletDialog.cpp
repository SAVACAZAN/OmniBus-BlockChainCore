#include "dialogs/CreateWalletDialog.h"
#include "core/LocalCrypto.h"
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QPushButton>
#include <QGroupBox>
#include <QMessageBox>
#include <QApplication>
#include <QClipboard>

namespace omni {

CreateWalletDialog::CreateWalletDialog(QWidget* parent)
    : QDialog(parent)
{
    setWindowTitle("Create New Wallet");
    setMinimumSize(540, 560);

    auto* mainLayout = new QVBoxLayout(this);
    m_stack = new QStackedWidget;
    mainLayout->addWidget(m_stack);

    setupStep1();
    setupStep2();
    setupStep3();

    goToStep(0);
}

// ═══════════════════════════════════════════════════
//  Step 1: Name, Password, Passphrase, Word Count
// ═══════════════════════════════════════════════════

void CreateWalletDialog::setupStep1() {
    auto* page = new QWidget;
    auto* layout = new QVBoxLayout(page);
    layout->setSpacing(10);
    layout->setContentsMargins(30, 20, 30, 20);

    auto* title = new QLabel("Create New Wallet");
    title->setStyleSheet("font-size: 22px; font-weight: bold; color: #00b3a4;");
    layout->addWidget(title);

    auto* desc = new QLabel("Choose a name, password, and optional BIP-39 passphrase.");
    desc->setStyleSheet("color: #8888aa; margin-bottom: 8px;");
    desc->setWordWrap(true);
    layout->addWidget(desc);

    // Wallet Name
    auto* nameLabel = new QLabel("Wallet Name:");
    nameLabel->setStyleSheet("font-weight: bold; color: #e0e0f0;");
    layout->addWidget(nameLabel);
    m_nameEdit = new QLineEdit;
    m_nameEdit->setPlaceholderText("My OmniBus Wallet");
    m_nameEdit->setMinimumHeight(36);
    layout->addWidget(m_nameEdit);

    // Password
    auto* passLabel = new QLabel("Encryption Password (min 8 chars):");
    passLabel->setStyleSheet("font-weight: bold; color: #e0e0f0; margin-top: 6px;");
    layout->addWidget(passLabel);
    m_passwordEdit = new QLineEdit;
    m_passwordEdit->setEchoMode(QLineEdit::Password);
    m_passwordEdit->setPlaceholderText("Enter password to encrypt wallet file");
    m_passwordEdit->setMinimumHeight(36);
    layout->addWidget(m_passwordEdit);

    // Confirm Password
    auto* confirmLabel = new QLabel("Confirm Password:");
    confirmLabel->setStyleSheet("font-weight: bold; color: #e0e0f0;");
    layout->addWidget(confirmLabel);
    m_confirmEdit = new QLineEdit;
    m_confirmEdit->setEchoMode(QLineEdit::Password);
    m_confirmEdit->setPlaceholderText("Re-enter password");
    m_confirmEdit->setMinimumHeight(36);
    layout->addWidget(m_confirmEdit);

    // BIP-39 Passphrase (optional)
    auto* ppLabel = new QLabel("BIP-39 Passphrase (optional, advanced):");
    ppLabel->setStyleSheet("font-weight: bold; color: #e0e0f0; margin-top: 6px;");
    layout->addWidget(ppLabel);
    m_passphraseEdit = new QLineEdit;
    m_passphraseEdit->setPlaceholderText("Leave empty for standard wallet");
    m_passphraseEdit->setMinimumHeight(36);
    layout->addWidget(m_passphraseEdit);
    auto* ppHint = new QLabel("A passphrase adds extra protection. Different passphrase = different wallet. If lost, funds are unrecoverable.");
    ppHint->setStyleSheet("color: #d9884a; font-size: 10px;");
    ppHint->setWordWrap(true);
    layout->addWidget(ppHint);

    // Mnemonic Word Count
    auto* wcLayout = new QHBoxLayout;
    auto* wcLabel = new QLabel("Mnemonic Length:");
    wcLabel->setStyleSheet("font-weight: bold; color: #e0e0f0;");
    wcLayout->addWidget(wcLabel);
    m_wordCountCombo = new QComboBox;
    m_wordCountCombo->addItem("12 words (128-bit)", 12);
    m_wordCountCombo->addItem("24 words (256-bit)", 24);
    m_wordCountCombo->setCurrentIndex(0);
    m_wordCountCombo->setMinimumHeight(32);
    m_wordCountCombo->setMinimumWidth(200);
    wcLayout->addWidget(m_wordCountCombo);
    wcLayout->addStretch();
    layout->addLayout(wcLayout);

    layout->addStretch();

    // Buttons
    auto* btnLayout = new QHBoxLayout;
    auto* cancelBtn = new QPushButton("Cancel");
    cancelBtn->setMinimumHeight(40);
    auto* nextBtn = new QPushButton("Generate Mnemonic  >");
    nextBtn->setMinimumHeight(40);
    nextBtn->setStyleSheet("background: #4a90d9; color: white; font-weight: bold; padding: 0 20px;");
    btnLayout->addWidget(cancelBtn);
    btnLayout->addStretch();
    btnLayout->addWidget(nextBtn);
    layout->addLayout(btnLayout);

    connect(cancelBtn, &QPushButton::clicked, this, &QDialog::reject);
    connect(nextBtn, &QPushButton::clicked, this, [this]() {
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
        // Generate mnemonic and go to step 2
        generateAndShowMnemonic();
        goToStep(1);
    });

    m_stack->addWidget(page);
}

// ═══════════════════════════════════════════════════
//  Step 2: Display Mnemonic for Backup
// ═══════════════════════════════════════════════════

void CreateWalletDialog::setupStep2() {
    auto* page = new QWidget;
    auto* layout = new QVBoxLayout(page);
    layout->setSpacing(10);
    layout->setContentsMargins(30, 20, 30, 20);

    auto* title = new QLabel("Backup Your Mnemonic");
    title->setStyleSheet("font-size: 22px; font-weight: bold; color: #00b3a4;");
    layout->addWidget(title);

    auto* warning = new QLabel(
        "CRITICAL: Write down these words in order. Store them offline in a safe place. "
        "This is the ONLY way to recover your wallet. NEVER share your mnemonic."
    );
    warning->setStyleSheet(
        "color: #ff6666; background: #2a1515; padding: 12px; border-radius: 6px; "
        "border: 1px solid #d94a4a; font-weight: bold;"
    );
    warning->setWordWrap(true);
    layout->addWidget(warning);

    m_mnemonicDisplay = new QTextEdit;
    m_mnemonicDisplay->setReadOnly(true);
    m_mnemonicDisplay->setMinimumHeight(120);
    m_mnemonicDisplay->setStyleSheet(
        "QTextEdit { background: #0d1117; color: #00ffcc; font-size: 17px; "
        "font-family: 'Consolas', 'Courier New', monospace; "
        "padding: 14px; border: 2px solid #00b3a4; border-radius: 8px; "
        "line-height: 1.6; letter-spacing: 0.5px; }"
    );
    layout->addWidget(m_mnemonicDisplay);

    // Button row: Copy + Regenerate
    auto* actionLayout = new QHBoxLayout;
    auto* copyBtn = new QPushButton("Copy to Clipboard");
    copyBtn->setMinimumHeight(32);
    copyBtn->setStyleSheet("background: #2a2d44; color: #e0e0f0; border: 1px solid #4a90d9; padding: 0 16px;");
    connect(copyBtn, &QPushButton::clicked, this, [this]() {
        QApplication::clipboard()->setText(m_mnemonic);
        QMessageBox::information(this, "Copied", "Mnemonic copied to clipboard.\nClear your clipboard after pasting!");
    });
    actionLayout->addWidget(copyBtn);

    m_regenerateBtn = new QPushButton("Regenerate");
    m_regenerateBtn->setMinimumHeight(32);
    m_regenerateBtn->setStyleSheet("background: #2a2d44; color: #d9884a; border: 1px solid #d9884a; padding: 0 16px;");
    connect(m_regenerateBtn, &QPushButton::clicked, this, [this]() {
        generateAndShowMnemonic();
    });
    actionLayout->addWidget(m_regenerateBtn);
    actionLayout->addStretch();
    layout->addLayout(actionLayout);

    m_backupCheck = new QCheckBox("I have written down my mnemonic phrase and stored it safely");
    m_backupCheck->setStyleSheet("color: #e0e0f0; margin-top: 8px; font-size: 12px;");
    layout->addWidget(m_backupCheck);

    layout->addStretch();

    // Buttons
    auto* btnLayout = new QHBoxLayout;
    auto* backBtn = new QPushButton("<  Back");
    backBtn->setMinimumHeight(40);
    auto* nextBtn = new QPushButton("Verify Mnemonic  >");
    nextBtn->setMinimumHeight(40);
    nextBtn->setStyleSheet("background: #4a90d9; color: white; font-weight: bold; padding: 0 20px;");
    btnLayout->addWidget(backBtn);
    btnLayout->addStretch();
    btnLayout->addWidget(nextBtn);
    layout->addLayout(btnLayout);

    connect(backBtn, &QPushButton::clicked, this, [this]() { goToStep(0); });
    connect(nextBtn, &QPushButton::clicked, this, [this]() {
        if (!m_backupCheck->isChecked()) {
            QMessageBox::warning(this, "Backup Required",
                "Please confirm that you have backed up your mnemonic phrase.");
            return;
        }
        goToStep(2);
    });

    m_stack->addWidget(page);
}

// ═══════════════════════════════════════════════════
//  Step 3: Verify Mnemonic
// ═══════════════════════════════════════════════════

void CreateWalletDialog::setupStep3() {
    auto* page = new QWidget;
    auto* layout = new QVBoxLayout(page);
    layout->setSpacing(10);
    layout->setContentsMargins(30, 20, 30, 20);

    auto* title = new QLabel("Verify Your Mnemonic");
    title->setStyleSheet("font-size: 22px; font-weight: bold; color: #00b3a4;");
    layout->addWidget(title);

    auto* desc = new QLabel("Type your mnemonic phrase below to confirm you saved it correctly:");
    desc->setStyleSheet("color: #8888aa; margin-bottom: 4px;");
    desc->setWordWrap(true);
    layout->addWidget(desc);

    m_verifyEdit = new QTextEdit;
    m_verifyEdit->setPlaceholderText("Type your mnemonic words separated by spaces...");
    m_verifyEdit->setMinimumHeight(100);
    m_verifyEdit->setStyleSheet(
        "QTextEdit { background: #0d1117; color: #e0e0f0; font-size: 15px; "
        "font-family: 'Consolas', 'Courier New', monospace; "
        "padding: 12px; border: 1px solid #3a3d54; border-radius: 6px; }"
    );
    layout->addWidget(m_verifyEdit);

    m_verifyStatus = new QLabel;
    m_verifyStatus->setStyleSheet("font-size: 12px; margin-top: 4px;");
    layout->addWidget(m_verifyStatus);

    // Live validation as user types
    connect(m_verifyEdit, &QTextEdit::textChanged, this, [this]() {
        QString entered = m_verifyEdit->toPlainText().simplified();
        QStringList words = entered.split(' ', Qt::SkipEmptyParts);
        int target = m_mnemonic.split(' ').size();
        if (words.size() < target) {
            m_verifyStatus->setText(QString("%1 / %2 words entered").arg(words.size()).arg(target));
            m_verifyStatus->setStyleSheet("color: #8888aa; font-size: 12px;");
        } else if (entered == m_mnemonic) {
            m_verifyStatus->setText("Mnemonic matches! You can create the wallet.");
            m_verifyStatus->setStyleSheet("color: #00b3a4; font-size: 12px; font-weight: bold;");
        } else {
            m_verifyStatus->setText("Mnemonic does NOT match. Check your words.");
            m_verifyStatus->setStyleSheet("color: #d94a4a; font-size: 12px;");
        }
    });

    layout->addStretch();

    // Buttons
    auto* btnLayout = new QHBoxLayout;
    auto* backBtn = new QPushButton("<  Back");
    backBtn->setMinimumHeight(40);
    auto* skipBtn = new QPushButton("Skip Verification");
    skipBtn->setMinimumHeight(40);
    skipBtn->setStyleSheet("color: #8888aa; padding: 0 16px;");
    auto* finishBtn = new QPushButton("Create Wallet");
    finishBtn->setMinimumHeight(40);
    finishBtn->setStyleSheet("background: #00b3a4; color: white; font-weight: bold; padding: 0 24px;");
    btnLayout->addWidget(backBtn);
    btnLayout->addWidget(skipBtn);
    btnLayout->addStretch();
    btnLayout->addWidget(finishBtn);
    layout->addLayout(btnLayout);

    connect(backBtn, &QPushButton::clicked, this, [this]() { goToStep(1); });
    connect(skipBtn, &QPushButton::clicked, this, &QDialog::accept);
    connect(finishBtn, &QPushButton::clicked, this, [this]() {
        if (verifyMnemonic()) {
            accept();
        }
    });

    m_stack->addWidget(page);
}

// ═══════════════════════════════════════════════════
//  Helpers
// ═══════════════════════════════════════════════════

void CreateWalletDialog::goToStep(int step) {
    m_stack->setCurrentIndex(step);
}

void CreateWalletDialog::generateAndShowMnemonic() {
    int wordCount = m_wordCountCombo->currentData().toInt();
    m_mnemonic = crypto::generateMnemonic(wordCount);

    // Format numbered for display
    QStringList words = m_mnemonic.split(' ');
    QString numbered;
    int cols = (words.size() <= 12) ? 3 : 4;
    for (int i = 0; i < words.size(); ++i) {
        numbered += QString("%1. %2").arg(i + 1, 2).arg(words[i].leftJustified(12));
        if ((i + 1) % cols == 0)
            numbered += "\n";
        else
            numbered += "  ";
    }
    m_mnemonicDisplay->setText(numbered.trimmed());
}

bool CreateWalletDialog::verifyMnemonic() {
    QString entered = m_verifyEdit->toPlainText().simplified();

    if (entered == m_mnemonic) {
        return true;
    } else {
        m_verifyStatus->setText("Mnemonic does NOT match. Please try again or go back.");
        m_verifyStatus->setStyleSheet("color: #d94a4a; font-size: 12px; font-weight: bold;");
        return false;
    }
}

QString CreateWalletDialog::walletName() const { return m_nameEdit ? m_nameEdit->text().trimmed() : ""; }
QString CreateWalletDialog::password() const { return m_passwordEdit ? m_passwordEdit->text() : ""; }
QString CreateWalletDialog::passphrase() const { return m_passphraseEdit ? m_passphraseEdit->text() : ""; }
int CreateWalletDialog::mnemonicWordCount() const {
    return m_wordCountCombo ? m_wordCountCombo->currentData().toInt() : 12;
}

} // namespace omni

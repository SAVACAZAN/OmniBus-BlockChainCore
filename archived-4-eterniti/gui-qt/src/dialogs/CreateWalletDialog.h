#pragma once

#include <QDialog>
#include <QLineEdit>
#include <QLabel>
#include <QTextEdit>
#include <QCheckBox>
#include <QComboBox>
#include <QStackedWidget>

namespace omni {

class CreateWalletDialog : public QDialog {
    Q_OBJECT
public:
    explicit CreateWalletDialog(QWidget* parent = nullptr);

    QString walletName() const;
    QString password() const;
    QString passphrase() const;
    int mnemonicWordCount() const;
    QString mnemonic() const { return m_mnemonic; }

private:
    void setupStep1(); // Name + Password + Passphrase + Word count
    void setupStep2(); // Show Mnemonic (backup)
    void setupStep3(); // Verify Mnemonic
    void goToStep(int step);
    void generateAndShowMnemonic();
    bool verifyMnemonic();

    QStackedWidget* m_stack = nullptr;

    // Step 1
    QLineEdit* m_nameEdit = nullptr;
    QLineEdit* m_passwordEdit = nullptr;
    QLineEdit* m_confirmEdit = nullptr;
    QLineEdit* m_passphraseEdit = nullptr;
    QComboBox* m_wordCountCombo = nullptr;

    // Step 2
    QTextEdit* m_mnemonicDisplay = nullptr;
    QCheckBox* m_backupCheck = nullptr;
    QPushButton* m_regenerateBtn = nullptr;

    // Step 3
    QTextEdit* m_verifyEdit = nullptr;
    QLabel* m_verifyStatus = nullptr;

    QString m_mnemonic;
};

} // namespace omni

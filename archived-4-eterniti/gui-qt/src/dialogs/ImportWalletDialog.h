#pragma once

#include <QDialog>
#include <QLineEdit>
#include <QTextEdit>
#include <QLabel>

namespace omni {

class ImportWalletDialog : public QDialog {
    Q_OBJECT
public:
    explicit ImportWalletDialog(QWidget* parent = nullptr);

    QString walletName() const;
    QString password() const;
    QString mnemonic() const;

private:
    QLineEdit* m_nameEdit = nullptr;
    QLineEdit* m_passwordEdit = nullptr;
    QLineEdit* m_confirmEdit = nullptr;
    QTextEdit* m_mnemonicEdit = nullptr;
    QLabel* m_statusLabel = nullptr;
};

} // namespace omni

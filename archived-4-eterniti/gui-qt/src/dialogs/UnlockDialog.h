#pragma once

#include <QDialog>
#include <QLineEdit>
#include <QLabel>
#include <QComboBox>

namespace omni {

class UnlockDialog : public QDialog {
    Q_OBJECT
public:
    explicit UnlockDialog(QWidget* parent = nullptr);

    QString selectedWalletId() const;
    QString password() const;

    // Populate wallet list
    void setWallets(const QList<QPair<QString, QString>>& wallets); // id, name

private:
    QComboBox* m_walletCombo = nullptr;
    QLineEdit* m_passwordEdit = nullptr;
    QLabel* m_statusLabel = nullptr;
};

} // namespace omni

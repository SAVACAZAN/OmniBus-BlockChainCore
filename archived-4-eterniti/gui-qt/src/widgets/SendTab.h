#pragma once

#include <QWidget>
#include <QLineEdit>
#include <QDoubleSpinBox>
#include <QLabel>
#include <QPushButton>
#include "core/Types.h"

namespace omni {

class SendTab : public QWidget {
    Q_OBJECT
public:
    explicit SendTab(QWidget* parent = nullptr);

public slots:
    void onWalletUpdated(const WalletInfo& info);

private slots:
    void onSendClicked();
    void onFeeEstimated();

private:
    void setupUi();

    QLineEdit*      m_recipientEdit;
    QDoubleSpinBox* m_amountSpin;
    QLabel*         m_feeLabel;
    QLabel*         m_balanceLabel;
    QLabel*         m_statusLabel;
    QPushButton*    m_sendBtn;

    qint64 m_estimatedFee = 1000;
    qint64 m_currentBalance = 0;
};

} // namespace omni

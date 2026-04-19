#include "widgets/SendTab.h"
#include "dialogs/ConfirmSendDialog.h"
#include "core/NodeService.h"

#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QFormLayout>
#include <QGroupBox>
#include <QFrame>
#include <QMessageBox>

namespace omni {

SendTab::SendTab(QWidget* parent)
    : QWidget(parent)
{
    setupUi();

    auto& svc = NodeService::instance();
    connect(&svc, &NodeService::walletUpdated, this, &SendTab::onWalletUpdated);

    // Estimate fee on startup
    onFeeEstimated();
}

void SendTab::setupUi() {
    auto* layout = new QVBoxLayout(this);
    layout->setContentsMargins(24, 24, 24, 24);
    layout->setSpacing(16);

    auto* title = new QLabel("Send OMNI");
    title->setObjectName("sectionTitle");
    layout->addWidget(title);

    // Balance display
    auto* balCard = new QFrame;
    balCard->setObjectName("card");
    auto* balLayout = new QHBoxLayout(balCard);
    auto* balLabel = new QLabel("Available Balance:");
    balLabel->setObjectName("dimLabel");
    m_balanceLabel = new QLabel("0.0000 OMNI");
    m_balanceLabel->setObjectName("balanceLabel");
    m_balanceLabel->setStyleSheet("font-size: 18px;");
    balLayout->addWidget(balLabel);
    balLayout->addStretch();
    balLayout->addWidget(m_balanceLabel);
    layout->addWidget(balCard);

    // Send form
    auto* formCard = new QFrame;
    formCard->setObjectName("card");
    auto* form = new QFormLayout(formCard);
    form->setSpacing(12);
    form->setContentsMargins(16, 16, 16, 16);

    m_recipientEdit = new QLineEdit;
    m_recipientEdit->setPlaceholderText("ob1q...");
    m_recipientEdit->setMinimumWidth(400);
    form->addRow("Recipient Address:", m_recipientEdit);

    m_amountSpin = new QDoubleSpinBox;
    m_amountSpin->setRange(0.0, 21000000.0);
    m_amountSpin->setDecimals(9);
    m_amountSpin->setSingleStep(0.001);
    m_amountSpin->setSuffix(" OMNI");
    form->addRow("Amount:", m_amountSpin);

    m_feeLabel = new QLabel("~1000 SAT");
    m_feeLabel->setObjectName("dimLabel");
    form->addRow("Estimated Fee:", m_feeLabel);

    layout->addWidget(formCard);

    // Status & Send button
    auto* btnLayout = new QHBoxLayout;
    m_statusLabel = new QLabel("");
    m_sendBtn = new QPushButton("Sign && Send");
    m_sendBtn->setMinimumHeight(40);
    m_sendBtn->setMinimumWidth(160);

    btnLayout->addWidget(m_statusLabel);
    btnLayout->addStretch();
    btnLayout->addWidget(m_sendBtn);
    layout->addLayout(btnLayout);

    layout->addStretch();

    connect(m_sendBtn, &QPushButton::clicked, this, &SendTab::onSendClicked);
}

void SendTab::onWalletUpdated(const WalletInfo& info) {
    m_currentBalance = info.balanceSAT;
    m_balanceLabel->setText(info.balanceOMNI + " OMNI");
    m_amountSpin->setMaximum(static_cast<double>(info.balanceSAT) / SAT_PER_OMNI);
}

void SendTab::onSendClicked() {
    QString to = m_recipientEdit->text().trimmed();
    double amountOmni = m_amountSpin->value();
    qint64 amountSat = omniToSat(amountOmni);

    if (to.isEmpty()) {
        QMessageBox::warning(this, "Error", "Please enter a recipient address.");
        return;
    }
    if (!to.startsWith("ob1q")) {
        QMessageBox::warning(this, "Error", "Address must start with 'ob1q'.");
        return;
    }
    if (amountSat <= 0) {
        QMessageBox::warning(this, "Error", "Amount must be greater than zero.");
        return;
    }
    if (amountSat + m_estimatedFee > m_currentBalance) {
        QMessageBox::warning(this, "Error", "Insufficient balance (including fee).");
        return;
    }

    // Confirm dialog
    ConfirmSendDialog dlg(to, amountSat, m_estimatedFee, this);
    if (dlg.exec() != QDialog::Accepted)
        return;

    m_sendBtn->setEnabled(false);
    m_statusLabel->setText("Broadcasting...");
    m_statusLabel->setStyleSheet("color: #ff9500;");

    NodeService::instance().rpc()->sendTransaction(to, amountSat,
        [this](const QJsonValue& result, const QString& err) {
            m_sendBtn->setEnabled(true);
            if (!err.isEmpty()) {
                m_statusLabel->setText("Failed: " + err);
                m_statusLabel->setStyleSheet("color: #d94a4a;");
            } else {
                m_statusLabel->setText("Sent! TxID: " + result.toObject()["txid"].toString().left(16) + "...");
                m_statusLabel->setStyleSheet("color: #00b3a4;");
                m_recipientEdit->clear();
                m_amountSpin->setValue(0);
            }
        }
    );
}

void SendTab::onFeeEstimated() {
    NodeService::instance().rpc()->estimateFee(
        [this](const QJsonValue& result, const QString& err) {
            if (err.isEmpty()) {
                auto fee = FeeEstimate::fromJson(result.toObject());
                m_estimatedFee = fee.medianFee > 0 ? fee.medianFee : 1000;
                m_feeLabel->setText(QString("~%1 SAT").arg(m_estimatedFee));
            }
        }
    );
}

} // namespace omni

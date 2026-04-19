#include "dialogs/ConfirmSendDialog.h"
#include "core/Types.h"

#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QPushButton>
#include <QFrame>

namespace omni {

ConfirmSendDialog::ConfirmSendDialog(const QString& to, qint64 amountSat, qint64 feeSat, QWidget* parent)
    : QDialog(parent)
{
    setWindowTitle("Confirm Transaction");
    setMinimumWidth(450);
    setModal(true);

    auto* layout = new QVBoxLayout(this);
    layout->setSpacing(16);
    layout->setContentsMargins(24, 24, 24, 24);

    auto* title = new QLabel("Confirm Send");
    title->setObjectName("sectionTitle");
    title->setAlignment(Qt::AlignCenter);
    layout->addWidget(title);

    auto* card = new QFrame;
    card->setObjectName("card");
    auto* cardLayout = new QVBoxLayout(card);
    cardLayout->setSpacing(8);

    auto addRow = [&](const QString& label, const QString& value, const QString& color = "#e0e0f0") {
        auto* row = new QHBoxLayout;
        auto* lbl = new QLabel(label);
        lbl->setObjectName("dimLabel");
        auto* val = new QLabel(value);
        val->setStyleSheet(QString("color: %1; font-weight: bold;").arg(color));
        val->setWordWrap(true);
        val->setTextInteractionFlags(Qt::TextSelectableByMouse);
        row->addWidget(lbl);
        row->addStretch();
        row->addWidget(val);
        cardLayout->addLayout(row);
    };

    addRow("To:", to, "#7b61ff");
    addRow("Amount:", satToOmni(amountSat) + " OMNI", "#00b3a4");
    addRow("Fee:", satToOmni(feeSat) + " OMNI", "#ff9500");
    addRow("Total:", satToOmni(amountSat + feeSat) + " OMNI", "#e0e0f0");

    layout->addWidget(card);

    // Warning
    auto* warn = new QLabel("This transaction cannot be reversed.");
    warn->setStyleSheet("color: #ff9500; font-size: 12px;");
    warn->setAlignment(Qt::AlignCenter);
    layout->addWidget(warn);

    // Buttons
    auto* btnLayout = new QHBoxLayout;
    auto* cancelBtn = new QPushButton("Cancel");
    cancelBtn->setObjectName("secondaryButton");
    auto* confirmBtn = new QPushButton("Confirm & Send");
    confirmBtn->setMinimumWidth(140);

    btnLayout->addWidget(cancelBtn);
    btnLayout->addStretch();
    btnLayout->addWidget(confirmBtn);
    layout->addLayout(btnLayout);

    connect(cancelBtn, &QPushButton::clicked, this, &QDialog::reject);
    connect(confirmBtn, &QPushButton::clicked, this, &QDialog::accept);
}

} // namespace omni

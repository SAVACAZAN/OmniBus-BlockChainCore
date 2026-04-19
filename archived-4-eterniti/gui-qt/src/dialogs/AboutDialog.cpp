#include "dialogs/AboutDialog.h"

#include <QVBoxLayout>
#include <QLabel>
#include <QPushButton>

namespace omni {

AboutDialog::AboutDialog(QWidget* parent)
    : QDialog(parent)
{
    setWindowTitle("About OmniBus-Qt");
    setFixedSize(420, 320);
    setModal(true);

    auto* layout = new QVBoxLayout(this);
    layout->setSpacing(12);
    layout->setContentsMargins(32, 24, 32, 24);
    layout->setAlignment(Qt::AlignCenter);

    auto* titleLabel = new QLabel("OmniBus-Qt");
    titleLabel->setStyleSheet("font-size: 24px; font-weight: bold; color: #4a90d9;");
    titleLabel->setAlignment(Qt::AlignCenter);

    auto* versionLabel = new QLabel("Version 1.0.0");
    versionLabel->setObjectName("dimLabel");
    versionLabel->setAlignment(Qt::AlignCenter);

    auto* descLabel = new QLabel(
        "Native Qt desktop wallet for the OmniBus blockchain.\n\n"
        "JSON-RPC 2.0 on port 8332\n"
        "WebSocket events on port 8334\n\n"
        "21M OMNI max supply\n"
        "1 OMNI = 1,000,000,000 SAT\n"
        "10s block time (10 sub-blocks)\n\n"
        "Post-quantum ready (ML-DSA, Falcon, SLH-DSA)");
    descLabel->setAlignment(Qt::AlignCenter);
    descLabel->setWordWrap(true);
    descLabel->setObjectName("dimLabel");

    auto* copyrightLabel = new QLabel("OmniBus Project - 2024-2026");
    copyrightLabel->setAlignment(Qt::AlignCenter);
    copyrightLabel->setStyleSheet("color: #555566; font-size: 11px;");

    auto* closeBtn = new QPushButton("Close");
    closeBtn->setFixedWidth(120);

    layout->addWidget(titleLabel);
    layout->addWidget(versionLabel);
    layout->addWidget(descLabel);
    layout->addStretch();
    layout->addWidget(copyrightLabel);
    layout->addWidget(closeBtn, 0, Qt::AlignCenter);

    connect(closeBtn, &QPushButton::clicked, this, &QDialog::accept);
}

} // namespace omni

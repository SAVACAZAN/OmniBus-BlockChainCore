#include "dialogs/SettingsDialog.h"
#include "core/Settings.h"

#include <QVBoxLayout>
#include <QFormLayout>
#include <QHBoxLayout>
#include <QPushButton>
#include <QGroupBox>
#include <QLabel>

namespace omni {

SettingsDialog::SettingsDialog(QWidget* parent)
    : QDialog(parent)
{
    setWindowTitle("Settings");
    setMinimumWidth(400);
    setModal(true);

    auto& s = Settings::instance();
    auto* layout = new QVBoxLayout(this);
    layout->setSpacing(16);
    layout->setContentsMargins(24, 24, 24, 24);

    // Connection group
    auto* connGroup = new QGroupBox("Node Connection");
    auto* connForm = new QFormLayout(connGroup);

    m_rpcHostEdit = new QLineEdit(s.rpcHost());
    m_rpcPortSpin = new QSpinBox;
    m_rpcPortSpin->setRange(1, 65535);
    m_rpcPortSpin->setValue(s.rpcPort());
    m_wsPortSpin = new QSpinBox;
    m_wsPortSpin->setRange(1, 65535);
    m_wsPortSpin->setValue(s.wsPort());

    connForm->addRow("RPC Host:", m_rpcHostEdit);
    connForm->addRow("RPC Port:", m_rpcPortSpin);
    connForm->addRow("WebSocket Port:", m_wsPortSpin);
    layout->addWidget(connGroup);

    // UI group
    auto* uiGroup = new QGroupBox("Interface");
    auto* uiLayout = new QVBoxLayout(uiGroup);

    m_trayCheck = new QCheckBox("Minimize to system tray on close");
    m_trayCheck->setChecked(s.minimizeToTray());
    uiLayout->addWidget(m_trayCheck);
    layout->addWidget(uiGroup);

    // Notifications group
    auto* notifGroup = new QGroupBox("Notifications");
    auto* notifLayout = new QVBoxLayout(notifGroup);

    m_notifyBlockCheck = new QCheckBox("Notify on new block mined");
    m_notifyBlockCheck->setChecked(s.notifyNewBlock());
    m_notifyTxCheck = new QCheckBox("Notify on incoming transaction");
    m_notifyTxCheck->setChecked(s.notifyIncomingTx());

    notifLayout->addWidget(m_notifyBlockCheck);
    notifLayout->addWidget(m_notifyTxCheck);
    layout->addWidget(notifGroup);

    // Buttons
    auto* btnLayout = new QHBoxLayout;
    auto* cancelBtn = new QPushButton("Cancel");
    cancelBtn->setObjectName("secondaryButton");
    auto* saveBtn = new QPushButton("Save");
    saveBtn->setMinimumWidth(120);

    btnLayout->addStretch();
    btnLayout->addWidget(cancelBtn);
    btnLayout->addWidget(saveBtn);
    layout->addLayout(btnLayout);

    connect(cancelBtn, &QPushButton::clicked, this, &QDialog::reject);
    connect(saveBtn, &QPushButton::clicked, this, &SettingsDialog::onSave);
}

void SettingsDialog::onSave() {
    auto& s = Settings::instance();
    s.setRpcHost(m_rpcHostEdit->text());
    s.setRpcPort(m_rpcPortSpin->value());
    s.setWsPort(m_wsPortSpin->value());
    s.setMinimizeToTray(m_trayCheck->isChecked());
    s.setNotifyNewBlock(m_notifyBlockCheck->isChecked());
    s.setNotifyIncomingTx(m_notifyTxCheck->isChecked());
    accept();
}

} // namespace omni

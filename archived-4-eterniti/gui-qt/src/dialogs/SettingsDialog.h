#pragma once

#include <QDialog>
#include <QLineEdit>
#include <QSpinBox>
#include <QCheckBox>

namespace omni {

class SettingsDialog : public QDialog {
    Q_OBJECT
public:
    explicit SettingsDialog(QWidget* parent = nullptr);

private slots:
    void onSave();

private:
    QLineEdit* m_rpcHostEdit;
    QSpinBox*  m_rpcPortSpin;
    QSpinBox*  m_wsPortSpin;
    QCheckBox* m_trayCheck;
    QCheckBox* m_notifyBlockCheck;
    QCheckBox* m_notifyTxCheck;
};

} // namespace omni

#pragma once

#include <QDialog>
#include <QString>

namespace omni {

class ConfirmSendDialog : public QDialog {
    Q_OBJECT
public:
    ConfirmSendDialog(const QString& to, qint64 amountSat, qint64 feeSat, QWidget* parent = nullptr);
};

} // namespace omni

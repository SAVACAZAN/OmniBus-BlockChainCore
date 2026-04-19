#pragma once

#include <QWidget>
#include <QLabel>
#include "core/Types.h"

namespace omni {

class AddressLabel;
class QRCodeWidget;

class ReceiveTab : public QWidget {
    Q_OBJECT
public:
    explicit ReceiveTab(QWidget* parent = nullptr);

public slots:
    void onWalletUpdated(const WalletInfo& info);

private:
    void setupUi();

    AddressLabel* m_addressLabel;
    QRCodeWidget* m_qrWidget;
    QLabel*       m_infoLabel;
};

} // namespace omni

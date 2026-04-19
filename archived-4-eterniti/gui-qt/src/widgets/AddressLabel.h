#pragma once

#include <QLabel>

namespace omni {

class AddressLabel : public QLabel {
    Q_OBJECT
public:
    explicit AddressLabel(const QString& address = "", QWidget* parent = nullptr);

    void setAddress(const QString& address);
    QString address() const { return m_address; }

protected:
    void mousePressEvent(QMouseEvent* event) override;

private:
    QString m_address;
};

} // namespace omni

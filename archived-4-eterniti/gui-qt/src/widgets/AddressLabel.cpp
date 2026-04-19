#include "widgets/AddressLabel.h"
#include <QClipboard>
#include <QApplication>
#include <QMouseEvent>
#include <QToolTip>

namespace omni {

AddressLabel::AddressLabel(const QString& address, QWidget* parent)
    : QLabel(parent)
{
    setObjectName("addressLabel");
    setCursor(Qt::PointingHandCursor);
    setToolTip("Click to copy address");
    setAddress(address);
}

void AddressLabel::setAddress(const QString& address) {
    m_address = address;
    setText(address);
    setToolTip("Click to copy: " + address);
}

void AddressLabel::mousePressEvent(QMouseEvent* event) {
    if (event->button() == Qt::LeftButton && !m_address.isEmpty()) {
        QApplication::clipboard()->setText(m_address);
        QToolTip::showText(event->globalPosition().toPoint(), "Copied!", this, {}, 1500);
    }
    QLabel::mousePressEvent(event);
}

} // namespace omni

#pragma once

#include <QWidget>
#include <QString>
#include <QImage>

namespace omni {

// Minimal QR Code generator using QPainter — supports up to ~80 char alphanumeric
class QRCodeWidget : public QWidget {
    Q_OBJECT
public:
    explicit QRCodeWidget(QWidget* parent = nullptr);

    void setData(const QString& data);
    QSize sizeHint() const override { return QSize(200, 200); }

protected:
    void paintEvent(QPaintEvent* event) override;

private:
    void generateQR();

    QString m_data;
    // Simple 2D grid representation: true = black module
    QVector<QVector<bool>> m_modules;
    int m_size = 0;
};

} // namespace omni

#pragma once

#include <QWidget>
#include <QTextEdit>
#include <QLineEdit>
#include <QStringList>

namespace omni {

class ConsoleTab : public QWidget {
    Q_OBJECT
public:
    explicit ConsoleTab(QWidget* parent = nullptr);

protected:
    bool eventFilter(QObject* obj, QEvent* event) override;

private slots:
    void executeCommand();

private:
    void setupUi();
    void appendOutput(const QString& text, const QString& color = "#e0e0f0");

    QTextEdit* m_output;
    QLineEdit* m_input;
    QStringList m_history;
    int m_historyIndex = -1;
};

} // namespace omni

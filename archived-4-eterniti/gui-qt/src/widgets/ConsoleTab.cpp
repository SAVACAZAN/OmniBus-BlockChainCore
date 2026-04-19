#include "widgets/ConsoleTab.h"
#include "core/NodeService.h"

#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QPushButton>
#include <QKeyEvent>
#include <QJsonDocument>
#include <QJsonArray>
#include <QScrollBar>
#include <QDateTime>

namespace omni {

ConsoleTab::ConsoleTab(QWidget* parent)
    : QWidget(parent)
{
    setupUi();
}

void ConsoleTab::setupUi() {
    auto* layout = new QVBoxLayout(this);
    layout->setContentsMargins(16, 16, 16, 16);
    layout->setSpacing(8);

    // Banner
    m_output = new QTextEdit;
    m_output->setReadOnly(true);
    m_output->setStyleSheet(
        "QTextEdit { font-family: 'Consolas', 'JetBrains Mono', monospace; "
        "font-size: 13px; background-color: #0d0f1a; "
        "border: 1px solid #2a2d4a; border-radius: 8px; padding: 8px; }");

    QString banner = QString(
        "<span style='color:#4a90d9;font-weight:bold;'>"
        "OmniBus-Qt Debug Console</span><br>"
        "<span style='color:#8888aa;'>Type a JSON-RPC method name followed by parameters.</span><br>"
        "<span style='color:#8888aa;'>Example: getblock 5</span><br>"
        "<span style='color:#8888aa;'>         getbalance</span><br>"
        "<span style='color:#8888aa;'>         sendtransaction ob1q... 1000000000</span><br>"
        "<span style='color:#2a2d4a;'>────────────────────────────────────────</span><br>");
    m_output->setHtml(banner);
    layout->addWidget(m_output, 1);

    // Input bar
    auto* inputBar = new QHBoxLayout;
    auto* prompt = new QLabel(">");
    prompt->setStyleSheet("color: #4a90d9; font-weight: bold; font-family: Consolas; font-size: 14px;");

    m_input = new QLineEdit;
    m_input->setPlaceholderText("Enter RPC method...");
    m_input->setStyleSheet(
        "QLineEdit { font-family: 'Consolas', monospace; font-size: 13px; }");
    m_input->installEventFilter(this);

    auto* sendBtn = new QPushButton("Send");
    sendBtn->setFixedWidth(80);

    inputBar->addWidget(prompt);
    inputBar->addWidget(m_input, 1);
    inputBar->addWidget(sendBtn);
    layout->addLayout(inputBar);

    connect(sendBtn, &QPushButton::clicked, this, &ConsoleTab::executeCommand);
    connect(m_input, &QLineEdit::returnPressed, this, &ConsoleTab::executeCommand);
}

bool ConsoleTab::eventFilter(QObject* obj, QEvent* event) {
    if (obj == m_input && event->type() == QEvent::KeyPress) {
        auto* ke = static_cast<QKeyEvent*>(event);
        if (ke->key() == Qt::Key_Up) {
            if (m_historyIndex < m_history.size() - 1) {
                m_historyIndex++;
                m_input->setText(m_history[m_history.size() - 1 - m_historyIndex]);
            }
            return true;
        }
        if (ke->key() == Qt::Key_Down) {
            if (m_historyIndex > 0) {
                m_historyIndex--;
                m_input->setText(m_history[m_history.size() - 1 - m_historyIndex]);
            } else {
                m_historyIndex = -1;
                m_input->clear();
            }
            return true;
        }
    }
    return QWidget::eventFilter(obj, event);
}

void ConsoleTab::executeCommand() {
    QString cmd = m_input->text().trimmed();
    if (cmd.isEmpty()) return;

    m_history.append(cmd);
    m_historyIndex = -1;
    m_input->clear();

    appendOutput("> " + cmd, "#4a90d9");

    // Parse: first word = method, rest = params
    QStringList parts = cmd.split(' ', Qt::SkipEmptyParts);
    QString method = parts.takeFirst();
    QJsonArray params;

    for (const auto& p : parts) {
        bool isNum = false;
        int intVal = p.toInt(&isNum);
        if (isNum) {
            params.append(intVal);
            continue;
        }
        double dblVal = p.toDouble(&isNum);
        if (isNum) {
            params.append(dblVal);
            continue;
        }
        params.append(p);
    }

    NodeService::instance().rpc()->rawRequest(method, params,
        [this, method](const QJsonValue& result, const QString& err) {
            if (!err.isEmpty()) {
                appendOutput("Error: " + err, "#d94a4a");
            } else {
                QJsonDocument doc;
                if (result.isObject())
                    doc = QJsonDocument(result.toObject());
                else if (result.isArray())
                    doc = QJsonDocument(result.toArray());
                else {
                    appendOutput(result.toVariant().toString(), "#00b3a4");
                    return;
                }
                appendOutput(doc.toJson(QJsonDocument::Indented), "#00b3a4");
            }
        }
    );
}

void ConsoleTab::appendOutput(const QString& text, const QString& color) {
    QString html = QString("<span style='color:%1;'>%2</span><br>")
        .arg(color, text.toHtmlEscaped().replace('\n', "<br>").replace(' ', "&nbsp;"));
    m_output->moveCursor(QTextCursor::End);
    m_output->insertHtml(html);
    m_output->verticalScrollBar()->setValue(m_output->verticalScrollBar()->maximum());
}

} // namespace omni

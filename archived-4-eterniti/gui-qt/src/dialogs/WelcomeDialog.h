#pragma once

#include <QDialog>

namespace omni {

class WelcomeDialog : public QDialog {
    Q_OBJECT
public:
    enum Choice { CreateWallet, ImportWallet, ConnectNode, NoChoice };

    explicit WelcomeDialog(QWidget* parent = nullptr);
    Choice userChoice() const { return m_choice; }

private:
    Choice m_choice = NoChoice;
};

} // namespace omni

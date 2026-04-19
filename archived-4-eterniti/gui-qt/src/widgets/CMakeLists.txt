add_library(omnibus-widgets STATIC
    OverviewTab.cpp
    SendTab.cpp
    ReceiveTab.cpp
    TransactionsTab.cpp
    MiningTab.cpp
    NetworkTab.cpp
    BlockExplorerTab.cpp
    ConsoleTab.cpp
    StatusBar.cpp
    AddressLabel.cpp
    QRCodeWidget.cpp
    MultiWalletTab.cpp
    ExchangeKeysTab.cpp
)

target_include_directories(omnibus-widgets PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/..)

target_link_libraries(omnibus-widgets PUBLIC
    omnibus-core
    omnibus-models
    Qt6::Core Qt6::Gui Qt6::Widgets
)

add_library(omnibus-dialogs STATIC
    AboutDialog.cpp
    SettingsDialog.cpp
    ConfirmSendDialog.cpp
    WelcomeDialog.cpp
    CreateWalletDialog.cpp
    ImportWalletDialog.cpp
    UnlockDialog.cpp
)

target_include_directories(omnibus-dialogs PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/..)

target_link_libraries(omnibus-dialogs PUBLIC
    omnibus-core
    Qt6::Core Qt6::Gui Qt6::Widgets
)

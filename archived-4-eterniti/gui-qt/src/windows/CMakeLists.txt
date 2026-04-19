add_library(omnibus-windows STATIC
    MainWindow.cpp
    TrayIcon.cpp
)

target_include_directories(omnibus-windows PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/..)

target_link_libraries(omnibus-windows PUBLIC
    omnibus-core
    omnibus-models
    omnibus-widgets
    omnibus-dialogs
    Qt6::Core Qt6::Gui Qt6::Widgets
)

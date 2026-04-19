cmake_minimum_required(VERSION 3.21)
project(OmniBus-Qt VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC ON)

find_package(Qt6 REQUIRED COMPONENTS
    Core Gui Widgets Network WebSockets
)

add_subdirectory(src/core)
add_subdirectory(src/models)
add_subdirectory(src/widgets)
add_subdirectory(src/dialogs)
add_subdirectory(src/windows)

qt_add_executable(omnibus-qt
    src/main.cpp
    resources/omnibus-qt.qrc
)

target_link_libraries(omnibus-qt PRIVATE
    omnibus-core
    omnibus-models
    omnibus-widgets
    omnibus-dialogs
    omnibus-windows
    Qt6::Core Qt6::Gui Qt6::Widgets
    Qt6::Network Qt6::WebSockets
)

if(WIN32)
    set_target_properties(omnibus-qt PROPERTIES WIN32_EXECUTABLE TRUE)
endif()

install(TARGETS omnibus-qt RUNTIME DESTINATION bin)

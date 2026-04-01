cmake_minimum_required(VERSION 3.21)
project(OmniBus-QtAda VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

# ── Find Qt6 ─────────────────────────────────────────────────
find_package(Qt6 REQUIRED COMPONENTS
    Core Gui Widgets Network WebSockets Svg
)

# ── Step 1: Build Ada SPARK vault DLL via gprbuild ───────────
set(ADA_VAULT_DIR "${CMAKE_SOURCE_DIR}/ada-vault")
set(ADA_VAULT_LIB "${ADA_VAULT_DIR}/lib/libomnibus_vault.dll")
set(ADA_VAULT_HEADER "${ADA_VAULT_DIR}/omnibus_vault.h")

set(GNAT_BIN "$ENV{USERPROFILE}/AppData/Local/alire/cache/toolchains/gnat_native_15.2.1_346e2e00/bin")
set(GPR_BIN  "$ENV{USERPROFILE}/AppData/Local/alire/cache/toolchains/gprbuild_25.0.1_1bcdf5e8/bin")

add_custom_command(
    OUTPUT ${ADA_VAULT_LIB}
    COMMAND ${CMAKE_COMMAND} -E env
        "PATH=${GNAT_BIN};${GPR_BIN};$ENV{PATH}"
        "${GPR_BIN}/gprbuild.exe"
        -P "${ADA_VAULT_DIR}/omnibus_vault.gpr"
        -XMODE=release
        --target=x86_64-w64-mingw32
        -j0
    WORKING_DIRECTORY ${ADA_VAULT_DIR}
    COMMENT "Building Ada SPARK vault library..."
    VERBATIM
)

add_custom_target(ada-vault-build DEPENDS ${ADA_VAULT_LIB})

# ── Step 2: Build Qt6 GUI ────────────────────────────────────

# Reuse sources from existing qt-gui where possible
get_filename_component(QT_GUI_ORIG "${CMAKE_SOURCE_DIR}/../qt-gui/src" ABSOLUTE)

# Core sources (mix: Ada bridge + original Qt sources)
set(CORE_SOURCES
    qt-gui/src/core/AdaVaultBridge.cpp
    ${QT_GUI_ORIG}/core/RpcClient.cpp
    ${QT_GUI_ORIG}/core/NodeService.cpp
    ${QT_GUI_ORIG}/core/Settings.cpp
    ${QT_GUI_ORIG}/core/Types.cpp
    ${QT_GUI_ORIG}/core/WalletManager.cpp
    ${QT_GUI_ORIG}/core/WebSocketClient.cpp
    ${QT_GUI_ORIG}/core/LocalCrypto.cpp
    ${QT_GUI_ORIG}/core/MultiChain.cpp
    ${QT_GUI_ORIG}/core/VaultStorage.cpp
)

# All other sources from original qt-gui
file(GLOB MODEL_SOURCES  "${QT_GUI_ORIG}/models/*.cpp")
file(GLOB WIDGET_SOURCES "${QT_GUI_ORIG}/widgets/*.cpp")
file(GLOB DIALOG_SOURCES "${QT_GUI_ORIG}/dialogs/*.cpp")
file(GLOB WINDOW_SOURCES "${QT_GUI_ORIG}/windows/*.cpp")

qt_add_executable(omnibus-qt-ada
    ${QT_GUI_ORIG}/main.cpp
    ${CORE_SOURCES}
    ${MODEL_SOURCES}
    ${WIDGET_SOURCES}
    ${DIALOG_SOURCES}
    ${WINDOW_SOURCES}
    ${QT_GUI_ORIG}/../resources/omnibus-qt.qrc
)

# Include paths
target_include_directories(omnibus-qt-ada PRIVATE
    ${CMAKE_SOURCE_DIR}/qt-gui/src   # AdaVaultBridge.h (via core/)
    ${QT_GUI_ORIG}                   # qt-gui/src for "core/X.h", "models/X.h"
    ${ADA_VAULT_DIR}                 # omnibus_vault.h
)

target_link_libraries(omnibus-qt-ada PRIVATE
    Qt6::Core Qt6::Gui Qt6::Widgets
    Qt6::Network Qt6::WebSockets Qt6::Svg
)

if(WIN32)
    target_link_libraries(omnibus-qt-ada PRIVATE crypt32)
    set_target_properties(omnibus-qt-ada PROPERTIES WIN32_EXECUTABLE TRUE)
endif()

# Depend on Ada vault build
add_dependencies(omnibus-qt-ada ada-vault-build)

# Copy Ada DLL next to executable
add_custom_command(TARGET omnibus-qt-ada POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${ADA_VAULT_DIR}/lib/libomnibus_vault.dll"
        "$<TARGET_FILE_DIR:omnibus-qt-ada>/omnibus_vault.dll"
    COMMENT "Copying Ada vault DLL to output..."
)

install(TARGETS omnibus-qt-ada RUNTIME DESTINATION bin)
install(FILES ${ADA_VAULT_LIB} DESTINATION bin)

add_library(omnibus-core STATIC
    Types.cpp
    RpcClient.cpp
    WebSocketClient.cpp
    NodeService.cpp
    Settings.cpp
    LocalCrypto.cpp
    WalletManager.cpp
    MultiChain.cpp
    VaultStorage.cpp
)

target_include_directories(omnibus-core PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/..)

target_link_libraries(omnibus-core PUBLIC
    Qt6::Core Qt6::Network Qt6::WebSockets
)

if(WIN32)
    target_link_libraries(omnibus-core PUBLIC crypt32)
endif()

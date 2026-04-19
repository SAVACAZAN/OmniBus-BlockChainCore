add_library(omnibus-models STATIC
    TransactionTableModel.cpp
    BlockTableModel.cpp
    PeerTableModel.cpp
    MinerTableModel.cpp
    MempoolTableModel.cpp
)

target_include_directories(omnibus-models PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/..)

target_link_libraries(omnibus-models PUBLIC
    omnibus-core
    Qt6::Core Qt6::Gui
)

// mempool_uaf.cpp
// Use-after-free în CTxMemPool::removeForBlock
class MempoolUaFExploit {
    // Adaugă tx, apoi elimină în aceeași iterație
};
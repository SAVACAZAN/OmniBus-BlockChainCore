// ============================================================
//  AdaVaultBridge.h  --  Qt wrapper around Ada SPARK vault DLL
//
//  Loads omnibus_vault.dll at runtime and exposes all vault
//  functions as a Qt-friendly singleton.
//
//  SECURITY: All crypto runs in SPARK-verified Ada code.
//  This C++ wrapper only marshals data.
// ============================================================
#pragma once

#include <QString>
#include <QVector>
#include <QLibrary>
#include <cstdint>

namespace omni {

// ─── Exchange/Status enums (mirror Ada) ─────────────────────
enum VaultExchange {
    VAULT_LCX      = 0,
    VAULT_KRAKEN   = 1,
    VAULT_COINBASE = 2,
    VAULT_EXCHANGE_COUNT = 3
};

enum VaultKeyStatus : uint8_t {
    KEY_STATUS_FREE    = 0,
    KEY_STATUS_PAID    = 1,
    KEY_STATUS_NOTPAID = 2
};

constexpr int VAULT_MAX_KEYS = 8;

struct VaultKeyEntry {
    QString  name;
    QString  apiKey;       // masked
    QString  apiSecret;    // only filled on explicit request
    uint8_t  status = KEY_STATUS_FREE;
    bool     inUse  = false;
};

// ─── Function pointer types ─────────────────────────────────
using FnVoid     = void(*)();
using FnInt      = int(*)();
using FnIntI     = int(*)(int);
using FnAddKey   = int(*)(int, const char*, const char*, const char*, int);
using FnDelKey   = int(*)(int, int);
using FnUpdKey   = int(*)(int, int, const char*, const char*, const char*, int);
using FnSetStat  = int(*)(int, int, int);
using FnGetKey   = int(*)(int, int, char*, int, char*, int, int*, int*);
using FnGetSec   = int(*)(int, int, char*, int);
using FnEncrypt  = int(*)(const char*, int, char*, int, int*);
using FnDecrypt  = int(*)(const char*, int, char*, int, int*);
using FnWipe     = void(*)(char*, int);
using FnGetPath  = const char*(*)();

// ─── AdaVaultBridge singleton ───────────────────────────────
class AdaVaultBridge {
public:
    static AdaVaultBridge& instance();

    bool loadLibrary(const QString& path = "omnibus_vault");
    bool isLibraryLoaded() const { return m_loaded; }

    // Lifecycle
    bool init();
    bool save();
    void lock();
    bool isVaultLoaded() const;

    // Key management
    bool addKey(VaultExchange ex, const QString& name,
                const QString& apiKey, const QString& secret,
                VaultKeyStatus status = KEY_STATUS_FREE);
    bool deleteKey(VaultExchange ex, int slot);
    bool updateKey(VaultExchange ex, int slot,
                   const QString& name, const QString& apiKey,
                   const QString& secret, VaultKeyStatus status);
    bool setStatus(VaultExchange ex, int slot, VaultKeyStatus status);

    // Queries
    int keyCount(VaultExchange ex) const;
    bool hasKeys(VaultExchange ex) const;
    VaultKeyEntry getKey(VaultExchange ex, int slot) const;
    QVector<VaultKeyEntry> listKeys(VaultExchange ex) const;

    // Info
    QString vaultFilePath() const;

    // Helpers
    static QString exchangeName(VaultExchange ex);
    static QString statusName(VaultKeyStatus st);

private:
    AdaVaultBridge();
    ~AdaVaultBridge();

    QLibrary m_lib;
    bool     m_loaded = false;

    // Function pointers
    FnVoid    m_libInit   = nullptr;
    FnInt     m_init      = nullptr;
    FnInt     m_lock      = nullptr;
    FnInt     m_save      = nullptr;
    FnInt     m_isLoaded  = nullptr;
    FnAddKey  m_addKey    = nullptr;
    FnDelKey  m_delKey    = nullptr;
    FnUpdKey  m_updKey    = nullptr;
    FnSetStat m_setStat   = nullptr;
    FnIntI    m_keyCount  = nullptr;
    FnIntI    m_hasKeys   = nullptr;
    FnGetKey  m_getKey    = nullptr;
    FnGetSec  m_getSec    = nullptr;
    FnWipe    m_wipe      = nullptr;
    FnGetPath m_getPath   = nullptr;
};

} // namespace omni

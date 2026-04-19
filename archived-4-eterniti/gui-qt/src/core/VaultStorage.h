// ============================================================
//  VaultStorage.h  —  Multi-key API vault (DPAPI encrypted)
//
//  Same DPAPI + OMNV v4 binary format as SuperVault.
//  Storage:  %APPDATA%\OmniBus-Qt\exchange-keys.vault
//  Crypto:   Windows DPAPI (tied to current user account)
//  Memory:   keys in plaintext while app runs, zeroed on Lock
// ============================================================
#pragma once

#include <QString>
#include <QVector>
#include <QByteArray>
#include <cstdint>

namespace omni {

// ─── Exchanges ───────────────────────────────────────────────
enum VaultExchange {
    VAULT_LCX      = 0,
    VAULT_KRAKEN   = 1,
    VAULT_COINBASE = 2,
    VAULT_EXCHANGE_COUNT = 3
};

// ─── Key status ──────────────────────────────────────────────
enum VaultKeyStatus : uint8_t {
    KEY_STATUS_FREE    = 0,
    KEY_STATUS_PAID    = 1,
    KEY_STATUS_NOTPAID = 2
};

// ─── Constants ───────────────────────────────────────────────
constexpr int VAULT_MAX_KEYS     = 8;
constexpr uint32_t VAULT_MAGIC   = 0x4F4D4E56; // "OMNV"
constexpr uint32_t VAULT_VERSION = 4;

// ─── Key entry ───────────────────────────────────────────────
struct VaultKeyEntry {
    QString  name;
    QString  apiKey;
    QString  apiSecret;
    uint8_t  status = KEY_STATUS_FREE;
    bool     inUse  = false;
};

// ─── VaultStorage singleton ──────────────────────────────────
class VaultStorage {
public:
    static VaultStorage& instance();

    // Lifecycle
    bool init();                // load from disk (or create empty)
    bool save();                // encrypt + write to disk
    void lock();                // SecureZeroMemory all keys in RAM

    // Key management
    bool addKey(VaultExchange ex, const QString& name,
                const QString& apiKey, const QString& apiSecret,
                VaultKeyStatus status = KEY_STATUS_FREE);
    bool deleteKey(VaultExchange ex, int slot);
    bool updateKey(VaultExchange ex, int slot,
                   const QString& name, const QString& apiKey,
                   const QString& apiSecret, VaultKeyStatus status);

    // Queries
    QVector<VaultKeyEntry> listKeys(VaultExchange ex) const;
    VaultKeyEntry getKey(VaultExchange ex, int slot) const;
    int keyCount(VaultExchange ex) const;
    bool hasKeys(VaultExchange ex) const;

    // Status
    bool setStatus(VaultExchange ex, int slot, VaultKeyStatus status);

    // Helpers
    static QString exchangeName(VaultExchange ex);
    static QString statusName(VaultKeyStatus st);
    static QString vaultFilePath();

    bool isLoaded() const { return m_loaded; }

private:
    VaultStorage();
    ~VaultStorage();

    // DPAPI helpers
    static QByteArray dpapiEncrypt(const QByteArray& plain);
    static QByteArray dpapiDecrypt(const QByteArray& cipher);

    // Serialization
    QByteArray serialize() const;
    bool deserialize(const QByteArray& data);

    // Secure wipe a QString
    static void secureWipe(QString& s);

    VaultKeyEntry m_stores[VAULT_EXCHANGE_COUNT][VAULT_MAX_KEYS];
    bool m_loaded = false;
};

} // namespace omni

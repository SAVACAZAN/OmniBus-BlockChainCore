// ============================================================
//  AdaVaultBridge.cpp  --  Runtime loading of Ada SPARK vault
// ============================================================

#include "AdaVaultBridge.h"
#include <QCoreApplication>
#include <QDir>
#include <cstring>

namespace omni {

AdaVaultBridge& AdaVaultBridge::instance() {
    static AdaVaultBridge s;
    return s;
}

AdaVaultBridge::AdaVaultBridge() = default;
AdaVaultBridge::~AdaVaultBridge() {
    if (m_loaded && m_lock) m_lock();
}

bool AdaVaultBridge::loadLibrary(const QString& path) {
    if (m_loaded) return true;

    // Try: same dir as exe, then system path
    QStringList searchPaths = {
        QCoreApplication::applicationDirPath() + "/" + path,
        path
    };

    for (const auto& p : searchPaths) {
        m_lib.setFileName(p);
        if (m_lib.load()) break;
    }

    if (!m_lib.isLoaded()) return false;

    // Resolve all symbols
    m_libInit  = (FnVoid)    m_lib.resolve("vault_lib_init");
    m_init     = (FnInt)     m_lib.resolve("vault_init");
    m_lock     = (FnInt)     m_lib.resolve("vault_lock");
    m_save     = (FnInt)     m_lib.resolve("vault_save");
    m_isLoaded = (FnInt)     m_lib.resolve("vault_is_loaded");
    m_addKey   = (FnAddKey)  m_lib.resolve("vault_add_key");
    m_delKey   = (FnDelKey)  m_lib.resolve("vault_delete_key");
    m_updKey   = (FnUpdKey)  m_lib.resolve("vault_update_key");
    m_setStat  = (FnSetStat) m_lib.resolve("vault_set_status");
    m_keyCount = (FnIntI)    m_lib.resolve("vault_key_count");
    m_hasKeys  = (FnIntI)    m_lib.resolve("vault_has_keys");
    m_getKey   = (FnGetKey)  m_lib.resolve("vault_get_key");
    m_getSec   = (FnGetSec)  m_lib.resolve("vault_get_secret");
    m_wipe     = (FnWipe)    m_lib.resolve("vault_wipe");
    m_getPath  = (FnGetPath) m_lib.resolve("vault_get_path");

    if (!m_init || !m_lock || !m_save || !m_isLoaded ||
        !m_addKey || !m_getKey) {
        m_lib.unload();
        return false;
    }

    // Initialize Ada runtime
    if (m_libInit) m_libInit();

    m_loaded = true;
    return true;
}

// ─── Lifecycle ──────────────────────────────────────────────

bool AdaVaultBridge::init() {
    if (!m_loaded || !m_init) return false;
    return m_init() == 0;
}

bool AdaVaultBridge::save() {
    if (!m_loaded || !m_save) return false;
    return m_save() == 0;
}

void AdaVaultBridge::lock() {
    if (m_loaded && m_lock) m_lock();
}

bool AdaVaultBridge::isVaultLoaded() const {
    if (!m_loaded || !m_isLoaded) return false;
    return m_isLoaded() == 1;
}

// ─── Key management ─────────────────────────────────────────

bool AdaVaultBridge::addKey(VaultExchange ex, const QString& name,
                            const QString& apiKey, const QString& secret,
                            VaultKeyStatus status) {
    if (!m_loaded || !m_addKey) return false;
    auto n = name.toUtf8();
    auto k = apiKey.toUtf8();
    auto s = secret.toUtf8();
    int rc = m_addKey(ex, n.constData(), k.constData(), s.constData(), status);

    // Secure wipe local copies
    if (m_wipe) {
        m_wipe(const_cast<char*>(s.constData()), s.size());
    }
    return rc == 0;
}

bool AdaVaultBridge::deleteKey(VaultExchange ex, int slot) {
    if (!m_loaded || !m_delKey) return false;
    return m_delKey(ex, slot) == 0;
}

bool AdaVaultBridge::updateKey(VaultExchange ex, int slot,
                               const QString& name, const QString& apiKey,
                               const QString& secret, VaultKeyStatus status) {
    if (!m_loaded || !m_updKey) return false;
    auto n = name.toUtf8();
    auto k = apiKey.toUtf8();
    auto s = secret.toUtf8();
    int rc = m_updKey(ex, slot, n.constData(), k.constData(),
                      s.constData(), status);
    if (m_wipe) {
        m_wipe(const_cast<char*>(s.constData()), s.size());
    }
    return rc == 0;
}

bool AdaVaultBridge::setStatus(VaultExchange ex, int slot,
                               VaultKeyStatus status) {
    if (!m_loaded || !m_setStat) return false;
    return m_setStat(ex, slot, status) == 0;
}

// ─── Queries ────────────────────────────────────────────────

int AdaVaultBridge::keyCount(VaultExchange ex) const {
    if (!m_loaded || !m_keyCount) return 0;
    return m_keyCount(ex);
}

bool AdaVaultBridge::hasKeys(VaultExchange ex) const {
    if (!m_loaded || !m_hasKeys) return false;
    return m_hasKeys(ex) == 1;
}

VaultKeyEntry AdaVaultBridge::getKey(VaultExchange ex, int slot) const {
    VaultKeyEntry e;
    if (!m_loaded || !m_getKey) return e;

    char nameBuf[256] = {};
    char keyBuf[256]  = {};
    int  statusOut = 0, inUseOut = 0;

    int rc = m_getKey(ex, slot, nameBuf, 256, keyBuf, 256,
                      &statusOut, &inUseOut);
    if (rc == 0) {
        e.inUse  = (inUseOut != 0);
        e.status = static_cast<VaultKeyStatus>(statusOut);
        e.name   = QString::fromUtf8(nameBuf);
        e.apiKey = QString::fromUtf8(keyBuf);
    }
    return e;
}

QVector<VaultKeyEntry> AdaVaultBridge::listKeys(VaultExchange ex) const {
    QVector<VaultKeyEntry> result;
    for (int i = 0; i < VAULT_MAX_KEYS; ++i) {
        auto e = getKey(ex, i);
        if (e.inUse) result.push_back(e);
    }
    return result;
}

// ─── Info ───────────────────────────────────────────────────

QString AdaVaultBridge::vaultFilePath() const {
    if (!m_loaded || !m_getPath) return "N/A";
    const char* p = m_getPath();
    return p ? QString::fromUtf8(p) : "N/A";
}

QString AdaVaultBridge::exchangeName(VaultExchange ex) {
    switch (ex) {
        case VAULT_LCX:      return "LCX";
        case VAULT_KRAKEN:   return "Kraken";
        case VAULT_COINBASE: return "Coinbase";
        default:             return "Unknown";
    }
}

QString AdaVaultBridge::statusName(VaultKeyStatus st) {
    switch (st) {
        case KEY_STATUS_FREE:    return "Free";
        case KEY_STATUS_PAID:    return "Paid";
        case KEY_STATUS_NOTPAID: return "Not Paid";
        default:                 return "Unknown";
    }
}

} // namespace omni

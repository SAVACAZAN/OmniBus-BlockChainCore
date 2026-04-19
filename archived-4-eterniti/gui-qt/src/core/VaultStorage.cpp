// ============================================================
//  VaultStorage.cpp  —  DPAPI-encrypted multi-key API vault
//
//  Binary format (v4) — compatible with OmnibusSidebar SuperVault:
//  [MAGIC:4][VERSION:4][EXCHANGE_COUNT:4]
//  for each exchange:
//    [SLOT_COUNT:4]
//    for each slot:
//      [IN_USE:1][STATUS:1]
//      [name_len:4][name_utf8]
//      [key_len:4][key_utf8]
//      [secret_len:4][secret_utf8]
//
//  Entire payload DPAPI-encrypted before disk write.
// ============================================================

#include "core/VaultStorage.h"

#include <QStandardPaths>
#include <QDir>
#include <QFile>
#include <QDataStream>
#include <QByteArray>

#ifdef Q_OS_WIN
#include <windows.h>
#include <wincrypt.h>
#pragma comment(lib, "crypt32.lib")
#endif

namespace omni {

// ─── Singleton ───────────────────────────────────────────────

VaultStorage& VaultStorage::instance() {
    static VaultStorage s;
    return s;
}

VaultStorage::VaultStorage() {
    // All slots default-constructed (inUse = false)
}

VaultStorage::~VaultStorage() {
    lock();
}

// ─── Helpers ─────────────────────────────────────────────────

QString VaultStorage::exchangeName(VaultExchange ex) {
    switch (ex) {
    case VAULT_LCX:      return "LCX";
    case VAULT_KRAKEN:   return "Kraken";
    case VAULT_COINBASE: return "Coinbase";
    default:             return "Unknown";
    }
}

QString VaultStorage::statusName(VaultKeyStatus st) {
    switch (st) {
    case KEY_STATUS_FREE:    return "Free";
    case KEY_STATUS_PAID:    return "Paid";
    case KEY_STATUS_NOTPAID: return "Not Paid";
    default:                 return "?";
    }
}

QString VaultStorage::vaultFilePath() {
    QString appData = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    // Separate file from OmnibusSidebar — own directory
    QDir dir(appData);
    dir.cdUp();
    QString vaultDir = dir.absolutePath() + "/OmniBus-Qt";
    QDir().mkpath(vaultDir);
    return vaultDir + "/exchange-keys.vault";
}

void VaultStorage::secureWipe(QString& s) {
    if (s.isEmpty()) return;
    // Overwrite the internal data
    auto* data = s.data();
    for (int i = 0; i < s.size(); ++i)
        data[i] = QChar(0);
    s.clear();
}

// ─── DPAPI ───────────────────────────────────────────────────

QByteArray VaultStorage::dpapiEncrypt(const QByteArray& plain) {
#ifdef Q_OS_WIN
    DATA_BLOB in;
    in.cbData = static_cast<DWORD>(plain.size());
    in.pbData = reinterpret_cast<BYTE*>(const_cast<char*>(plain.data()));

    DATA_BLOB out = {};
    if (!CryptProtectData(&in, L"OmnibusSidebarVault", nullptr, nullptr, nullptr,
                          CRYPTPROTECT_UI_FORBIDDEN, &out)) {
        return {};
    }
    QByteArray result(reinterpret_cast<const char*>(out.pbData), static_cast<int>(out.cbData));
    LocalFree(out.pbData);
    return result;
#else
    // Fallback: no encryption (Linux/macOS — placeholder)
    return plain;
#endif
}

QByteArray VaultStorage::dpapiDecrypt(const QByteArray& cipher) {
#ifdef Q_OS_WIN
    DATA_BLOB in;
    in.cbData = static_cast<DWORD>(cipher.size());
    in.pbData = reinterpret_cast<BYTE*>(const_cast<char*>(cipher.data()));

    DATA_BLOB out = {};
    if (!CryptUnprotectData(&in, nullptr, nullptr, nullptr, nullptr, 0, &out)) {
        return {};
    }
    QByteArray result(reinterpret_cast<const char*>(out.pbData), static_cast<int>(out.cbData));
    SecureZeroMemory(out.pbData, out.cbData);
    LocalFree(out.pbData);
    return result;
#else
    return cipher;
#endif
}

// ─── Serialization ───────────────────────────────────────────

QByteArray VaultStorage::serialize() const {
    QByteArray buf;
    QDataStream ds(&buf, QIODevice::WriteOnly);
    ds.setByteOrder(QDataStream::LittleEndian);

    ds << VAULT_MAGIC;
    ds << VAULT_VERSION;
    ds << static_cast<uint32_t>(VAULT_EXCHANGE_COUNT);

    for (int ex = 0; ex < VAULT_EXCHANGE_COUNT; ++ex) {
        // Count active slots
        uint32_t count = 0;
        for (int s = 0; s < VAULT_MAX_KEYS; ++s) {
            if (m_stores[ex][s].inUse) ++count;
        }
        ds << static_cast<uint32_t>(VAULT_MAX_KEYS); // always write all 8 slots

        for (int s = 0; s < VAULT_MAX_KEYS; ++s) {
            const auto& slot = m_stores[ex][s];
            ds << static_cast<uint8_t>(slot.inUse ? 1 : 0);
            ds << static_cast<uint8_t>(slot.status);

            QByteArray nameUtf8 = slot.name.toUtf8();
            ds << static_cast<uint32_t>(nameUtf8.size());
            ds.writeRawData(nameUtf8.data(), nameUtf8.size());

            QByteArray keyUtf8 = slot.apiKey.toUtf8();
            ds << static_cast<uint32_t>(keyUtf8.size());
            ds.writeRawData(keyUtf8.data(), keyUtf8.size());

            QByteArray secretUtf8 = slot.apiSecret.toUtf8();
            ds << static_cast<uint32_t>(secretUtf8.size());
            ds.writeRawData(secretUtf8.data(), secretUtf8.size());
        }
    }
    return buf;
}

bool VaultStorage::deserialize(const QByteArray& data) {
    QDataStream ds(data);
    ds.setByteOrder(QDataStream::LittleEndian);

    uint32_t magic, version, exCount;
    ds >> magic >> version >> exCount;

    if (magic != VAULT_MAGIC || version != VAULT_VERSION) {
        // Incompatible format — start fresh
        return false;
    }

    if (exCount > static_cast<uint32_t>(VAULT_EXCHANGE_COUNT))
        exCount = VAULT_EXCHANGE_COUNT;

    for (uint32_t ex = 0; ex < exCount; ++ex) {
        uint32_t slotCount;
        ds >> slotCount;
        if (slotCount > VAULT_MAX_KEYS)
            slotCount = VAULT_MAX_KEYS;

        for (uint32_t s = 0; s < slotCount; ++s) {
            uint8_t inUse, status;
            ds >> inUse >> status;

            uint32_t nameLen;
            ds >> nameLen;
            QByteArray nameUtf8(nameLen, '\0');
            ds.readRawData(nameUtf8.data(), nameLen);

            uint32_t keyLen;
            ds >> keyLen;
            QByteArray keyUtf8(keyLen, '\0');
            ds.readRawData(keyUtf8.data(), keyLen);

            uint32_t secretLen;
            ds >> secretLen;
            QByteArray secretUtf8(secretLen, '\0');
            ds.readRawData(secretUtf8.data(), secretLen);

            auto& slot = m_stores[ex][s];
            slot.inUse     = (inUse != 0);
            slot.status    = static_cast<VaultKeyStatus>(status);
            slot.name      = QString::fromUtf8(nameUtf8);
            slot.apiKey    = QString::fromUtf8(keyUtf8);
            slot.apiSecret = QString::fromUtf8(secretUtf8);
        }
    }
    return true;
}

// ─── Lifecycle ───────────────────────────────────────────────

bool VaultStorage::init() {
    QString path = vaultFilePath();
    QFile f(path);
    if (!f.exists()) {
        m_loaded = true; // empty vault, will be saved on first addKey
        return true;
    }
    if (!f.open(QIODevice::ReadOnly)) {
        return false;
    }
    QByteArray cipher = f.readAll();
    f.close();

    QByteArray plain = dpapiDecrypt(cipher);
    if (plain.isEmpty()) {
        // Could not decrypt — maybe different user or corrupt file
        m_loaded = true; // start fresh
        return false;
    }

    m_loaded = deserialize(plain);

    // Secure-wipe the plaintext buffer
#ifdef Q_OS_WIN
    SecureZeroMemory(plain.data(), plain.size());
#else
    memset(plain.data(), 0, plain.size());
#endif

    return m_loaded;
}

bool VaultStorage::save() {
    QByteArray plain = serialize();
    QByteArray cipher = dpapiEncrypt(plain);

    // Secure-wipe plaintext
#ifdef Q_OS_WIN
    SecureZeroMemory(plain.data(), plain.size());
#else
    memset(plain.data(), 0, plain.size());
#endif

    if (cipher.isEmpty()) return false;

    QString path = vaultFilePath();
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        return false;
    }
    f.write(cipher);
    f.close();
    return true;
}

void VaultStorage::lock() {
    for (int ex = 0; ex < VAULT_EXCHANGE_COUNT; ++ex) {
        for (int s = 0; s < VAULT_MAX_KEYS; ++s) {
            auto& slot = m_stores[ex][s];
            secureWipe(slot.name);
            secureWipe(slot.apiKey);
            secureWipe(slot.apiSecret);
            slot.inUse  = false;
            slot.status = KEY_STATUS_FREE;
        }
    }
    m_loaded = false;
}

// ─── Key Management ──────────────────────────────────────────

bool VaultStorage::addKey(VaultExchange ex, const QString& name,
                          const QString& apiKey, const QString& apiSecret,
                          VaultKeyStatus status)
{
    if (ex < 0 || ex >= VAULT_EXCHANGE_COUNT) return false;

    // Find first empty slot
    for (int s = 0; s < VAULT_MAX_KEYS; ++s) {
        if (!m_stores[ex][s].inUse) {
            m_stores[ex][s].inUse     = true;
            m_stores[ex][s].name      = name;
            m_stores[ex][s].apiKey    = apiKey;
            m_stores[ex][s].apiSecret = apiSecret;
            m_stores[ex][s].status    = status;
            return save();
        }
    }
    return false; // all 8 slots full
}

bool VaultStorage::deleteKey(VaultExchange ex, int slot) {
    if (ex < 0 || ex >= VAULT_EXCHANGE_COUNT) return false;
    if (slot < 0 || slot >= VAULT_MAX_KEYS) return false;

    auto& entry = m_stores[ex][slot];
    secureWipe(entry.name);
    secureWipe(entry.apiKey);
    secureWipe(entry.apiSecret);
    entry.inUse  = false;
    entry.status = KEY_STATUS_FREE;

    return save();
}

bool VaultStorage::updateKey(VaultExchange ex, int slot,
                             const QString& name, const QString& apiKey,
                             const QString& apiSecret, VaultKeyStatus status)
{
    if (ex < 0 || ex >= VAULT_EXCHANGE_COUNT) return false;
    if (slot < 0 || slot >= VAULT_MAX_KEYS) return false;

    auto& entry = m_stores[ex][slot];
    entry.inUse     = true;
    entry.name      = name;
    entry.apiKey    = apiKey;
    entry.apiSecret = apiSecret;
    entry.status    = status;

    return save();
}

// ─── Queries ─────────────────────────────────────────────────

QVector<VaultKeyEntry> VaultStorage::listKeys(VaultExchange ex) const {
    QVector<VaultKeyEntry> result;
    if (ex < 0 || ex >= VAULT_EXCHANGE_COUNT) return result;
    for (int s = 0; s < VAULT_MAX_KEYS; ++s) {
        if (m_stores[ex][s].inUse)
            result.append(m_stores[ex][s]);
    }
    return result;
}

VaultKeyEntry VaultStorage::getKey(VaultExchange ex, int slot) const {
    if (ex >= 0 && ex < VAULT_EXCHANGE_COUNT && slot >= 0 && slot < VAULT_MAX_KEYS)
        return m_stores[ex][slot];
    return {};
}

int VaultStorage::keyCount(VaultExchange ex) const {
    if (ex < 0 || ex >= VAULT_EXCHANGE_COUNT) return 0;
    int n = 0;
    for (int s = 0; s < VAULT_MAX_KEYS; ++s)
        if (m_stores[ex][s].inUse) ++n;
    return n;
}

bool VaultStorage::hasKeys(VaultExchange ex) const {
    return keyCount(ex) > 0;
}

bool VaultStorage::setStatus(VaultExchange ex, int slot, VaultKeyStatus status) {
    if (ex < 0 || ex >= VAULT_EXCHANGE_COUNT) return false;
    if (slot < 0 || slot >= VAULT_MAX_KEYS) return false;
    if (!m_stores[ex][slot].inUse) return false;

    m_stores[ex][slot].status = status;
    return save();
}

} // namespace omni

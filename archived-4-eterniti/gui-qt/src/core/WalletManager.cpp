#include "core/WalletManager.h"
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QStandardPaths>
#include <QUuid>

namespace omni {

// ══════════════════════════════════════════════════════════════════
//  WalletAddress
// ══════════════════════════════════════════════════════════════════

QJsonObject WalletAddress::toJson() const {
    QJsonObject obj;
    obj["index"] = index;
    obj["path"] = path;
    obj["address"] = address;
    obj["label"] = label;
    obj["pubkey"] = QString::fromLatin1(pubkey.toBase64());
    return obj;
}

WalletAddress WalletAddress::fromJson(const QJsonObject& obj) {
    WalletAddress a;
    a.index = obj["index"].toInt();
    a.path = obj["path"].toString();
    a.address = obj["address"].toString();
    a.label = obj["label"].toString();
    a.pubkey = QByteArray::fromBase64(obj["pubkey"].toString().toLatin1());
    return a;
}

// ══════════════════════════════════════════════════════════════════
//  WalletMeta
// ══════════════════════════════════════════════════════════════════

QJsonObject WalletMeta::toJson() const {
    QJsonObject obj;
    obj["id"] = id;
    obj["name"] = name;
    obj["filename"] = filename;
    obj["createdAt"] = createdAt.toString(Qt::ISODate);
    obj["lastAccessed"] = lastAccessed.toString(Qt::ISODate);
    obj["addressCount"] = addressCount;
    obj["firstAddress"] = firstAddress;
    return obj;
}

WalletMeta WalletMeta::fromJson(const QJsonObject& obj) {
    WalletMeta m;
    m.id = obj["id"].toString();
    m.name = obj["name"].toString();
    m.filename = obj["filename"].toString();
    m.createdAt = QDateTime::fromString(obj["createdAt"].toString(), Qt::ISODate);
    m.lastAccessed = QDateTime::fromString(obj["lastAccessed"].toString(), Qt::ISODate);
    m.addressCount = obj["addressCount"].toInt();
    m.firstAddress = obj["firstAddress"].toString();
    return m;
}

// ══════════════════════════════════════════════════════════════════
//  WalletFile (encrypted JSON)
// ══════════════════════════════════════════════════════════════════

QJsonObject WalletManager::WalletFile::toJson() const {
    QJsonObject obj;
    obj["id"] = id;
    obj["name"] = name;
    obj["createdAt"] = createdAt.toString(Qt::ISODate);
    obj["encryptedSeed"] = QString::fromLatin1(encryptedSeed.toBase64());
    obj["iv"] = QString::fromLatin1(iv.toBase64());
    obj["salt"] = QString::fromLatin1(salt.toBase64());
    obj["addresses"] = addressesJson;
    obj["nextIndex"] = nextIndex;
    obj["version"] = 1;
    return obj;
}

WalletManager::WalletFile WalletManager::WalletFile::fromJson(const QJsonObject& obj) {
    WalletFile f;
    f.id = obj["id"].toString();
    f.name = obj["name"].toString();
    f.createdAt = QDateTime::fromString(obj["createdAt"].toString(), Qt::ISODate);
    f.encryptedSeed = QByteArray::fromBase64(obj["encryptedSeed"].toString().toLatin1());
    f.iv = QByteArray::fromBase64(obj["iv"].toString().toLatin1());
    f.salt = QByteArray::fromBase64(obj["salt"].toString().toLatin1());
    f.addressesJson = obj["addresses"].toArray();
    f.nextIndex = obj["nextIndex"].toInt();
    return f;
}

// ══════════════════════════════════════════════════════════════════
//  WalletManager singleton
// ══════════════════════════════════════════════════════════════════

WalletManager& WalletManager::instance() {
    static WalletManager mgr;
    return mgr;
}

WalletManager::WalletManager(QObject* parent)
    : QObject(parent)
{
    // Ensure wallet directory exists
    QDir().mkpath(walletDir());
    loadIndex();
}

QString WalletManager::walletDir() const {
    return QStandardPaths::writableLocation(QStandardPaths::AppDataLocation) + "/wallets";
}

// ══════════════════════════════════════════════════════════════════
//  Index management
// ══════════════════════════════════════════════════════════════════

void WalletManager::saveIndex() {
    QJsonArray arr;
    for (const auto& m : m_walletIndex)
        arr.append(m.toJson());

    QJsonObject root;
    root["wallets"] = arr;
    root["version"] = 1;

    QFile file(walletDir() + "/index.json");
    if (file.open(QIODevice::WriteOnly)) {
        file.write(QJsonDocument(root).toJson(QJsonDocument::Indented));
    }
}

void WalletManager::loadIndex() {
    m_walletIndex.clear();
    QFile file(walletDir() + "/index.json");
    if (!file.open(QIODevice::ReadOnly)) return;

    QJsonDocument doc = QJsonDocument::fromJson(file.readAll());
    QJsonArray arr = doc.object()["wallets"].toArray();
    for (const auto& v : arr)
        m_walletIndex.append(WalletMeta::fromJson(v.toObject()));
}

QList<WalletMeta> WalletManager::listWallets() const {
    return m_walletIndex;
}

bool WalletManager::hasWallets() const {
    return !m_walletIndex.isEmpty();
}

// ══════════════════════════════════════════════════════════════════
//  Encryption helpers
// ══════════════════════════════════════════════════════════════════

QByteArray WalletManager::deriveEncryptionKey(const QString& password, const QByteArray& salt) const {
    // PBKDF2-HMAC-SHA512 with 100k iterations -> 32 bytes for AES-256
    return crypto::pbkdf2HmacSha512(password.toUtf8(), salt, 100000, 32);
}

// ══════════════════════════════════════════════════════════════════
//  Create wallet
// ══════════════════════════════════════════════════════════════════

WalletManager::CreateResult WalletManager::createWallet(const QString& name, const QString& password, int mnemonicWords, const QString& passphrase) {
    CreateResult result;

    if (name.trimmed().isEmpty()) {
        result.error = "Wallet name cannot be empty";
        return result;
    }
    if (password.size() < 8) {
        result.error = "Password must be at least 8 characters";
        return result;
    }

    // Generate mnemonic
    QString mnemonic = crypto::generateMnemonic(mnemonicWords);
    result.mnemonic = mnemonic;

    // Derive seed (with optional BIP-39 passphrase)
    QByteArray seed = crypto::mnemonicToSeed(mnemonic, passphrase);

    // Encrypt seed
    QByteArray salt = crypto::randomBytes(32);
    QByteArray iv = crypto::randomBytes(16);
    QByteArray encKey = deriveEncryptionKey(password, salt);
    QByteArray encryptedSeed = crypto::aes256Encrypt(seed, encKey, iv);

    // Generate wallet ID and first address
    QString walletId = QUuid::createUuid().toString(QUuid::WithoutBraces);

    // Derive master key and first address
    auto masterKey = crypto::masterKeyFromSeed(seed);
    // OmniBus derivation path: m/44'/9999'/0'/0/index
    auto addrKey = crypto::derivePath(masterKey, "m/44'/9999'/0'/0/0");
    QByteArray pubkey = crypto::privateToPublicKey(addrKey.key);
    QString address = crypto::pubkeyToOb1qAddress(pubkey);

    WalletAddress firstAddr;
    firstAddr.index = 0;
    firstAddr.path = "m/44'/9999'/0'/0/0";
    firstAddr.address = address;
    firstAddr.label = "Default";
    firstAddr.pubkey = pubkey;

    // Build wallet file
    WalletFile wf;
    wf.id = walletId;
    wf.name = name;
    wf.createdAt = QDateTime::currentDateTimeUtc();
    wf.encryptedSeed = encryptedSeed;
    wf.iv = iv;
    wf.salt = salt;
    wf.addressesJson = QJsonArray{ firstAddr.toJson() };
    wf.nextIndex = 1;

    // Save wallet file
    QString filename = walletId + ".wallet";
    QFile file(walletDir() + "/" + filename);
    if (!file.open(QIODevice::WriteOnly)) {
        result.error = "Failed to write wallet file: " + file.errorString();
        return result;
    }
    file.write(QJsonDocument(wf.toJson()).toJson(QJsonDocument::Indented));
    file.close();

    // Update index
    WalletMeta meta;
    meta.id = walletId;
    meta.name = name;
    meta.filename = filename;
    meta.createdAt = wf.createdAt;
    meta.lastAccessed = wf.createdAt;
    meta.addressCount = 1;
    meta.firstAddress = address;
    m_walletIndex.append(meta);
    saveIndex();

    // Set as current (unlocked)
    m_unlocked = true;
    m_currentId = walletId;
    m_currentName = name;
    m_seed = seed;
    m_masterKey = masterKey;
    m_addresses = { firstAddr };
    m_walletFile = wf;

    result.success = true;
    result.walletId = walletId;

    emit walletUnlocked();
    emit walletChanged(walletId, name);

    return result;
}

// ══════════════════════════════════════════════════════════════════
//  Import wallet
// ══════════════════════════════════════════════════════════════════

WalletManager::CreateResult WalletManager::importWallet(const QString& name, const QString& password, const QString& mnemonic, const QString& passphrase) {
    CreateResult result;

    if (!crypto::validateMnemonic(mnemonic)) {
        result.error = "Invalid mnemonic phrase";
        return result;
    }
    if (name.trimmed().isEmpty()) {
        result.error = "Wallet name cannot be empty";
        return result;
    }
    if (password.size() < 8) {
        result.error = "Password must be at least 8 characters";
        return result;
    }

    // Derive seed from mnemonic (with optional BIP-39 passphrase)
    QByteArray seed = crypto::mnemonicToSeed(mnemonic, passphrase);

    // Encrypt seed
    QByteArray salt = crypto::randomBytes(32);
    QByteArray iv = crypto::randomBytes(16);
    QByteArray encKey = deriveEncryptionKey(password, salt);
    QByteArray encryptedSeed = crypto::aes256Encrypt(seed, encKey, iv);

    QString walletId = QUuid::createUuid().toString(QUuid::WithoutBraces);

    // Derive first address
    auto masterKey = crypto::masterKeyFromSeed(seed);
    auto addrKey = crypto::derivePath(masterKey, "m/44'/9999'/0'/0/0");
    QByteArray pubkey = crypto::privateToPublicKey(addrKey.key);
    QString address = crypto::pubkeyToOb1qAddress(pubkey);

    WalletAddress firstAddr;
    firstAddr.index = 0;
    firstAddr.path = "m/44'/9999'/0'/0/0";
    firstAddr.address = address;
    firstAddr.label = "Default";
    firstAddr.pubkey = pubkey;

    WalletFile wf;
    wf.id = walletId;
    wf.name = name;
    wf.createdAt = QDateTime::currentDateTimeUtc();
    wf.encryptedSeed = encryptedSeed;
    wf.iv = iv;
    wf.salt = salt;
    wf.addressesJson = QJsonArray{ firstAddr.toJson() };
    wf.nextIndex = 1;

    QString filename = walletId + ".wallet";
    QFile file(walletDir() + "/" + filename);
    if (!file.open(QIODevice::WriteOnly)) {
        result.error = "Failed to write wallet file";
        return result;
    }
    file.write(QJsonDocument(wf.toJson()).toJson(QJsonDocument::Indented));
    file.close();

    WalletMeta meta;
    meta.id = walletId;
    meta.name = name;
    meta.filename = filename;
    meta.createdAt = wf.createdAt;
    meta.lastAccessed = wf.createdAt;
    meta.addressCount = 1;
    meta.firstAddress = address;
    m_walletIndex.append(meta);
    saveIndex();

    m_unlocked = true;
    m_currentId = walletId;
    m_currentName = name;
    m_seed = seed;
    m_masterKey = masterKey;
    m_addresses = { firstAddr };
    m_walletFile = wf;

    result.success = true;
    result.walletId = walletId;
    result.mnemonic = mnemonic;

    emit walletUnlocked();
    emit walletChanged(walletId, name);

    return result;
}

// ══════════════════════════════════════════════════════════════════
//  Unlock / Lock
// ══════════════════════════════════════════════════════════════════

bool WalletManager::unlock(const QString& walletId, const QString& password) {
    if (!loadWallet(walletId)) return false;

    // Decrypt seed
    QByteArray encKey = deriveEncryptionKey(password, m_walletFile.salt);
    QByteArray seed = crypto::aes256Decrypt(m_walletFile.encryptedSeed, encKey, m_walletFile.iv);

    if (seed.isEmpty() || seed.size() != 64) {
        // Wrong password or corrupt data
        return false;
    }

    m_seed = seed;
    m_masterKey = crypto::masterKeyFromSeed(seed);

    // Verify: derive first address and check it matches
    auto addrKey = crypto::derivePath(m_masterKey, "m/44'/9999'/0'/0/0");
    QByteArray pubkey = crypto::privateToPublicKey(addrKey.key);
    QString address = crypto::pubkeyToOb1qAddress(pubkey);

    if (!m_addresses.isEmpty() && m_addresses[0].address != address) {
        // Decryption produced garbage
        m_seed.clear();
        return false;
    }

    m_unlocked = true;
    m_currentId = walletId;
    m_currentName = m_walletFile.name;

    // Update last accessed
    for (auto& meta : m_walletIndex) {
        if (meta.id == walletId) {
            meta.lastAccessed = QDateTime::currentDateTimeUtc();
            break;
        }
    }
    saveIndex();

    emit walletUnlocked();
    emit walletChanged(m_currentId, m_currentName);
    return true;
}

void WalletManager::lock() {
    m_seed.fill('\0');
    m_seed.clear();
    m_unlocked = false;
    emit walletLocked();
}

bool WalletManager::loadWallet(const QString& walletId) {
    // Find filename from index
    QString filename;
    for (const auto& meta : m_walletIndex) {
        if (meta.id == walletId) {
            filename = meta.filename;
            break;
        }
    }
    if (filename.isEmpty()) return false;

    QFile file(walletDir() + "/" + filename);
    if (!file.open(QIODevice::ReadOnly)) return false;

    QJsonDocument doc = QJsonDocument::fromJson(file.readAll());
    m_walletFile = WalletFile::fromJson(doc.object());

    // Load addresses
    m_addresses.clear();
    for (const auto& v : m_walletFile.addressesJson)
        m_addresses.append(WalletAddress::fromJson(v.toObject()));

    return true;
}

bool WalletManager::saveWallet() {
    if (m_currentId.isEmpty()) return false;

    // Update addresses in wallet file
    QJsonArray addrs;
    for (const auto& a : m_addresses)
        addrs.append(a.toJson());
    m_walletFile.addressesJson = addrs;

    QString filename;
    for (const auto& meta : m_walletIndex) {
        if (meta.id == m_currentId) {
            filename = meta.filename;
            break;
        }
    }
    if (filename.isEmpty()) return false;

    QFile file(walletDir() + "/" + filename);
    if (!file.open(QIODevice::WriteOnly)) return false;
    file.write(QJsonDocument(m_walletFile.toJson()).toJson(QJsonDocument::Indented));
    return true;
}

// ══════════════════════════════════════════════════════════════════
//  Address generation
// ══════════════════════════════════════════════════════════════════

QString WalletManager::primaryAddress() const {
    if (m_addresses.isEmpty()) return {};
    return m_addresses.first().address;
}

WalletAddress WalletManager::generateAddress(const QString& label) {
    if (!m_unlocked) return {};

    int idx = m_walletFile.nextIndex;
    QString path = QString("m/44'/9999'/0'/0/%1").arg(idx);
    auto addrKey = crypto::derivePath(m_masterKey, path);
    QByteArray pubkey = crypto::privateToPublicKey(addrKey.key);
    QString address = crypto::pubkeyToOb1qAddress(pubkey);

    WalletAddress addr;
    addr.index = idx;
    addr.path = path;
    addr.address = address;
    addr.label = label.isEmpty() ? QString("Address #%1").arg(idx) : label;
    addr.pubkey = pubkey;

    m_addresses.append(addr);
    m_walletFile.nextIndex = idx + 1;

    // Update index meta
    for (auto& meta : m_walletIndex) {
        if (meta.id == m_currentId) {
            meta.addressCount = m_addresses.size();
            break;
        }
    }

    saveWallet();
    saveIndex();

    emit addressGenerated(addr);
    return addr;
}

// ══════════════════════════════════════════════════════════════════
//  Signing
// ══════════════════════════════════════════════════════════════════

QByteArray WalletManager::getPrivateKey(int addressIndex) const {
    if (!m_unlocked) return {};
    QString path = QString("m/44'/9999'/0'/0/%1").arg(addressIndex);
    auto key = crypto::derivePath(m_masterKey, path);
    return key.key;
}

QByteArray WalletManager::signTransaction(const QByteArray& txHash, int addressIndex) const {
    QByteArray privKey = getPrivateKey(addressIndex);
    if (privKey.isEmpty()) return {};
    return crypto::ecdsaSign(txHash, privKey);
}

// ══════════════════════════════════════════════════════════════════
//  Switch / Delete / Rename
// ══════════════════════════════════════════════════════════════════

bool WalletManager::switchWallet(const QString& walletId, const QString& password) {
    lock();
    return unlock(walletId, password);
}

bool WalletManager::deleteWallet(const QString& walletId) {
    if (walletId == m_currentId) lock();

    QString filename;
    for (int i = 0; i < m_walletIndex.size(); ++i) {
        if (m_walletIndex[i].id == walletId) {
            filename = m_walletIndex[i].filename;
            m_walletIndex.removeAt(i);
            break;
        }
    }
    if (filename.isEmpty()) return false;

    QFile::remove(walletDir() + "/" + filename);
    saveIndex();
    return true;
}

bool WalletManager::renameWallet(const QString& walletId, const QString& newName) {
    for (auto& meta : m_walletIndex) {
        if (meta.id == walletId) {
            meta.name = newName;
            saveIndex();

            if (walletId == m_currentId) {
                m_currentName = newName;
                m_walletFile.name = newName;
                saveWallet();
                emit walletChanged(m_currentId, m_currentName);
            }
            return true;
        }
    }
    return false;
}

QString WalletManager::exportMnemonic(const QString& password) const {
    if (!m_unlocked || m_walletFile.salt.isEmpty()) return {};

    QByteArray encKey = deriveEncryptionKey(password, m_walletFile.salt);
    QByteArray seed = crypto::aes256Decrypt(m_walletFile.encryptedSeed, encKey, m_walletFile.iv);
    if (seed.isEmpty()) return {};

    // We can't reverse seed->mnemonic, so we don't support this from seed alone.
    // The mnemonic is only shown at creation time.
    return "Mnemonic export not available. Please use the backup shown at wallet creation.";
}

} // namespace omni

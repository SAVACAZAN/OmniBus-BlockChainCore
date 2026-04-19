#pragma once

#include <QObject>
#include <QString>
#include <QStringList>
#include <QJsonObject>
#include <QJsonArray>
#include <QList>
#include <QDateTime>
#include "core/LocalCrypto.h"

namespace omni {

// ─── Wallet file data structures ───

struct WalletAddress {
    int index = 0;
    QString path;          // e.g. "m/44'/9999'/0'/0/0"
    QString address;       // ob1q...
    QString label;
    QByteArray pubkey;     // 33-byte compressed

    QJsonObject toJson() const;
    static WalletAddress fromJson(const QJsonObject& obj);
};

struct WalletMeta {
    QString id;            // UUID
    QString name;
    QString filename;      // relative filename in wallet dir
    QDateTime createdAt;
    QDateTime lastAccessed;
    int addressCount = 0;
    QString firstAddress;  // for display

    QJsonObject toJson() const;
    static WalletMeta fromJson(const QJsonObject& obj);
};

// ─── The main wallet manager ───

class WalletManager : public QObject {
    Q_OBJECT
public:
    static WalletManager& instance();

    // Wallet directory
    QString walletDir() const;

    // List available wallets
    QList<WalletMeta> listWallets() const;

    // Create a new wallet (returns mnemonic for backup)
    struct CreateResult {
        bool success = false;
        QString error;
        QString mnemonic;
        QString walletId;
    };
    CreateResult createWallet(const QString& name, const QString& password,
                              int mnemonicWords = 12, const QString& passphrase = "");

    // Import wallet from mnemonic
    CreateResult importWallet(const QString& name, const QString& password,
                              const QString& mnemonic, const QString& passphrase = "");

    // Unlock / lock
    bool unlock(const QString& walletId, const QString& password);
    void lock();
    bool isUnlocked() const { return m_unlocked; }

    // Current wallet info
    QString currentWalletId() const { return m_currentId; }
    QString currentWalletName() const { return m_currentName; }
    QList<WalletAddress> addresses() const { return m_addresses; }
    QString primaryAddress() const;

    // Generate next receive address
    WalletAddress generateAddress(const QString& label = "");

    // Get the 64-byte seed (only when unlocked, for multi-chain derivation)
    QByteArray getSeed() const { return m_unlocked ? m_seed : QByteArray(); }

    // Get private key for signing (only when unlocked)
    QByteArray getPrivateKey(int addressIndex) const;

    // Sign a transaction hash
    QByteArray signTransaction(const QByteArray& txHash, int addressIndex = 0) const;

    // Switch wallet
    bool switchWallet(const QString& walletId, const QString& password);

    // Delete wallet
    bool deleteWallet(const QString& walletId);

    // Rename wallet
    bool renameWallet(const QString& walletId, const QString& newName);

    // Check if any wallets exist (for first-launch detection)
    bool hasWallets() const;

    // Export mnemonic (requires password verification)
    QString exportMnemonic(const QString& password) const;

signals:
    void walletChanged(const QString& walletId, const QString& walletName);
    void addressGenerated(const WalletAddress& addr);
    void walletLocked();
    void walletUnlocked();

private:
    explicit WalletManager(QObject* parent = nullptr);

    // Wallet file format (JSON encrypted)
    struct WalletFile {
        QString id;
        QString name;
        QDateTime createdAt;
        QByteArray encryptedSeed;  // AES-256-CBC encrypted 64-byte seed
        QByteArray iv;             // 16-byte IV
        QByteArray salt;           // 32-byte salt for PBKDF2
        QJsonArray addressesJson;
        int nextIndex = 0;

        QJsonObject toJson() const;
        static WalletFile fromJson(const QJsonObject& obj);
    };

    bool saveWallet();
    bool loadWallet(const QString& walletId);
    QByteArray deriveEncryptionKey(const QString& password, const QByteArray& salt) const;

    // Index file tracking all wallets
    void saveIndex();
    void loadIndex();

    // State
    bool m_unlocked = false;
    QString m_currentId;
    QString m_currentName;
    QByteArray m_seed;             // 64-byte seed (only in memory when unlocked)
    crypto::ExtendedKey m_masterKey;
    QList<WalletAddress> m_addresses;
    WalletFile m_walletFile;
    QList<WalletMeta> m_walletIndex;
};

} // namespace omni

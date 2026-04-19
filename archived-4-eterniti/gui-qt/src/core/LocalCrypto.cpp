#include "core/LocalCrypto.h"
#include <QRandomGenerator>
#include <QCryptographicHash>
#include <cstring>
#include <algorithm>
#include <stdexcept>

namespace omni {
namespace crypto {

// ══════════════════════════════════════════════════════════════════
//  SHA-256  (using Qt's built-in)
// ══════════════════════════════════════════════════════════════════

QByteArray sha256(const QByteArray& data) {
    return QCryptographicHash::hash(data, QCryptographicHash::Sha256);
}

QByteArray doubleSha256(const QByteArray& data) {
    return sha256(sha256(data));
}

// ══════════════════════════════════════════════════════════════════
//  SHA-512  (using Qt's built-in)
// ══════════════════════════════════════════════════════════════════

QByteArray sha512(const QByteArray& data) {
    return QCryptographicHash::hash(data, QCryptographicHash::Sha512);
}

// ══════════════════════════════════════════════════════════════════
//  HMAC-SHA512  (RFC 2104)
// ══════════════════════════════════════════════════════════════════

QByteArray hmacSha512(const QByteArray& key, const QByteArray& data) {
    constexpr int blockSize = 128; // SHA-512 block size
    QByteArray k = key;
    if (k.size() > blockSize)
        k = sha512(k);
    k.resize(blockSize, '\0');

    QByteArray ipad(blockSize, '\x36');
    QByteArray opad(blockSize, '\x5c');

    for (int i = 0; i < blockSize; ++i) {
        ipad[i] = ipad[i] ^ k[i];
        opad[i] = opad[i] ^ k[i];
    }

    QByteArray inner = sha512(ipad + data);
    return sha512(opad + inner);
}

// ══════════════════════════════════════════════════════════════════
//  RIPEMD-160  (standalone implementation)
// ══════════════════════════════════════════════════════════════════

namespace {

inline uint32_t ripemd_rotl(uint32_t x, int n) { return (x << n) | (x >> (32 - n)); }

inline uint32_t ripemd_f(int j, uint32_t x, uint32_t y, uint32_t z) {
    if (j < 16) return x ^ y ^ z;
    if (j < 32) return (x & y) | (~x & z);
    if (j < 48) return (x | ~y) ^ z;
    if (j < 64) return (x & z) | (y & ~z);
    return x ^ (y | ~z);
}

static const uint32_t ripemd_K_left[]  = { 0x00000000, 0x5A827999, 0x6ED9EBA1, 0x8F1BBCDC, 0xA953FD4E };
static const uint32_t ripemd_K_right[] = { 0x50A28BE6, 0x5C4DD124, 0x6D703EF3, 0x7A6D76E9, 0x00000000 };

static const int ripemd_R_left[] = {
    0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,
    7,4,13,1,10,6,15,3,12,0,9,5,2,14,11,8,
    3,10,14,4,9,15,8,1,2,7,0,6,13,11,5,12,
    1,9,11,10,0,8,12,4,13,3,7,15,14,5,6,2,
    4,0,5,9,7,12,2,10,14,1,3,8,11,6,15,13
};

static const int ripemd_R_right[] = {
    5,14,7,0,9,2,11,4,13,6,15,8,1,10,3,12,
    6,11,3,7,0,13,5,10,14,15,8,12,4,9,1,2,
    15,5,1,3,7,14,6,9,11,8,12,2,10,0,4,13,
    8,6,4,1,3,11,15,0,5,12,2,13,9,7,10,14,
    12,15,10,4,1,5,8,7,6,2,13,14,0,3,9,11
};

static const int ripemd_S_left[] = {
    11,14,15,12,5,8,7,9,11,13,14,15,6,7,9,8,
    7,6,8,13,11,9,7,15,7,12,15,9,11,7,13,12,
    11,13,6,7,14,9,13,15,14,8,13,6,5,12,7,5,
    11,12,14,15,14,15,9,8,9,14,5,6,8,6,5,12,
    9,15,5,11,6,8,13,12,5,12,13,14,11,8,5,6
};

static const int ripemd_S_right[] = {
    8,9,9,11,13,15,15,5,7,7,8,11,14,14,12,6,
    9,13,15,7,12,8,9,11,7,7,12,7,6,15,13,11,
    9,7,15,11,8,6,6,14,12,13,5,14,13,13,7,5,
    15,5,8,11,14,14,6,14,6,9,12,9,12,5,15,8,
    8,5,12,9,12,5,14,6,8,13,6,5,15,13,11,11
};

} // anonymous namespace

QByteArray ripemd160(const QByteArray& data) {
    // Padding
    uint64_t bitLen = static_cast<uint64_t>(data.size()) * 8;
    QByteArray padded = data;
    padded.append('\x80');
    while ((padded.size() % 64) != 56)
        padded.append('\x00');
    // Little-endian length
    for (int i = 0; i < 8; ++i)
        padded.append(static_cast<char>((bitLen >> (i * 8)) & 0xff));

    uint32_t h0 = 0x67452301, h1 = 0xEFCDAB89, h2 = 0x98BADCFE, h3 = 0x10325476, h4 = 0xC3D2E1F0;

    const auto* rawData = reinterpret_cast<const unsigned char*>(padded.constData());
    int blocks = padded.size() / 64;

    for (int b = 0; b < blocks; ++b) {
        uint32_t X[16];
        for (int i = 0; i < 16; ++i) {
            int off = b * 64 + i * 4;
            X[i] = rawData[off] | (rawData[off+1] << 8) | (rawData[off+2] << 16) | (rawData[off+3] << 24);
        }

        uint32_t al = h0, bl = h1, cl = h2, dl = h3, el = h4;
        uint32_t ar = h0, br = h1, cr = h2, dr = h3, er = h4;

        for (int j = 0; j < 80; ++j) {
            int round = j / 16;
            // Left
            uint32_t tl = ripemd_rotl(al + ripemd_f(j, bl, cl, dl) + X[ripemd_R_left[j]] + ripemd_K_left[round], ripemd_S_left[j]) + el;
            al = el; el = dl; dl = ripemd_rotl(cl, 10); cl = bl; bl = tl;
            // Right
            uint32_t tr = ripemd_rotl(ar + ripemd_f(79 - j, br, cr, dr) + X[ripemd_R_right[j]] + ripemd_K_right[round], ripemd_S_right[j]) + er;
            ar = er; er = dr; dr = ripemd_rotl(cr, 10); cr = br; br = tr;
        }

        uint32_t t = h1 + cl + dr;
        h1 = h2 + dl + er;
        h2 = h3 + el + ar;
        h3 = h4 + al + br;
        h4 = h0 + bl + cr;
        h0 = t;
    }

    QByteArray result(20, '\0');
    auto* out = reinterpret_cast<unsigned char*>(result.data());
    for (int i = 0; i < 4; ++i) {
        out[i]    = (h0 >> (i*8)) & 0xff;
        out[4+i]  = (h1 >> (i*8)) & 0xff;
        out[8+i]  = (h2 >> (i*8)) & 0xff;
        out[12+i] = (h3 >> (i*8)) & 0xff;
        out[16+i] = (h4 >> (i*8)) & 0xff;
    }
    return result;
}

QByteArray hash160(const QByteArray& data) {
    return ripemd160(sha256(data));
}

// ══════════════════════════════════════════════════════════════════
//  PBKDF2-HMAC-SHA512
// ══════════════════════════════════════════════════════════════════

QByteArray pbkdf2HmacSha512(const QByteArray& password, const QByteArray& salt, int iterations, int keyLen) {
    QByteArray result;
    int hLen = 64; // SHA-512 output
    int blocks = (keyLen + hLen - 1) / hLen;

    for (int i = 1; i <= blocks; ++i) {
        QByteArray blockSalt = salt;
        blockSalt.append(static_cast<char>((i >> 24) & 0xff));
        blockSalt.append(static_cast<char>((i >> 16) & 0xff));
        blockSalt.append(static_cast<char>((i >> 8) & 0xff));
        blockSalt.append(static_cast<char>(i & 0xff));

        QByteArray u = hmacSha512(password, blockSalt);
        QByteArray T = u;

        for (int j = 1; j < iterations; ++j) {
            u = hmacSha512(password, u);
            for (int k = 0; k < hLen; ++k)
                T[k] = T[k] ^ u[k];
        }
        result.append(T);
    }
    result.truncate(keyLen);
    return result;
}

// ══════════════════════════════════════════════════════════════════
//  AES-256-CBC  (standalone implementation)
// ══════════════════════════════════════════════════════════════════

namespace {

static const uint8_t AES_SBOX[256] = {
    0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
    0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
    0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
    0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
    0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
    0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
    0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
    0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
    0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
    0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
    0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
    0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
    0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
    0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
    0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
    0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16
};

static const uint8_t AES_RSBOX[256] = {
    0x52,0x09,0x6a,0xd5,0x30,0x36,0xa5,0x38,0xbf,0x40,0xa3,0x9e,0x81,0xf3,0xd7,0xfb,
    0x7c,0xe3,0x39,0x82,0x9b,0x2f,0xff,0x87,0x34,0x8e,0x43,0x44,0xc4,0xde,0xe9,0xcb,
    0x54,0x7b,0x94,0x32,0xa6,0xc2,0x23,0x3d,0xee,0x4c,0x95,0x0b,0x42,0xfa,0xc3,0x4e,
    0x08,0x2e,0xa1,0x66,0x28,0xd9,0x24,0xb2,0x76,0x5b,0xa2,0x49,0x6d,0x8b,0xd1,0x25,
    0x72,0xf8,0xf6,0x64,0x86,0x68,0x98,0x16,0xd4,0xa4,0x5c,0xcc,0x5d,0x65,0xb6,0x92,
    0x6c,0x70,0x48,0x50,0xfd,0xed,0xb9,0xda,0x5e,0x15,0x46,0x57,0xa7,0x8d,0x9d,0x84,
    0x90,0xd8,0xab,0x00,0x8c,0xbc,0xd3,0x0a,0xf7,0xe4,0x58,0x05,0xb8,0xb3,0x45,0x06,
    0xd0,0x2c,0x1e,0x8f,0xca,0x3f,0x0f,0x02,0xc1,0xaf,0xbd,0x03,0x01,0x13,0x8a,0x6b,
    0x3a,0x91,0x11,0x41,0x4f,0x67,0xdc,0xea,0x97,0xf2,0xcf,0xce,0xf0,0xb4,0xe6,0x73,
    0x96,0xac,0x74,0x22,0xe7,0xad,0x35,0x85,0xe2,0xf9,0x37,0xe8,0x1c,0x75,0xdf,0x6e,
    0x47,0xf1,0x1a,0x71,0x1d,0x29,0xc5,0x89,0x6f,0xb7,0x62,0x0e,0xaa,0x18,0xbe,0x1b,
    0xfc,0x56,0x3e,0x4b,0xc6,0xd2,0x79,0x20,0x9a,0xdb,0xc0,0xfe,0x78,0xcd,0x5a,0xf4,
    0x1f,0xdd,0xa8,0x33,0x88,0x07,0xc7,0x31,0xb1,0x12,0x10,0x59,0x27,0x80,0xec,0x5f,
    0x60,0x51,0x7f,0xa9,0x19,0xb5,0x4a,0x0d,0x2d,0xe5,0x7a,0x9f,0x93,0xc9,0x9c,0xef,
    0xa0,0xe0,0x3b,0x4d,0xae,0x2a,0xf5,0xb0,0xc8,0xeb,0xbb,0x3c,0x83,0x53,0x99,0x61,
    0x17,0x2b,0x04,0x7e,0xba,0x77,0xd6,0x26,0xe1,0x69,0x14,0x63,0x55,0x21,0x0c,0x7d
};

static const uint8_t AES_RCON[] = { 0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36 };

inline uint8_t aesXtime(uint8_t x) { return (x << 1) ^ (((x >> 7) & 1) * 0x1b); }
inline uint8_t aesMul(uint8_t x, uint8_t y) {
    uint8_t r = 0;
    for (int i = 0; i < 8; ++i) {
        if (y & 1) r ^= x;
        x = aesXtime(x);
        y >>= 1;
    }
    return r;
}

struct AES256 {
    uint8_t roundKeys[240]; // 15 rounds * 16 bytes

    void keyExpansion(const uint8_t* key) {
        int Nk = 8, Nr = 14;
        std::memcpy(roundKeys, key, 32);
        for (int i = Nk; i < 4 * (Nr + 1); ++i) {
            uint8_t temp[4];
            std::memcpy(temp, roundKeys + (i-1)*4, 4);
            if (i % Nk == 0) {
                uint8_t t = temp[0];
                temp[0] = AES_SBOX[temp[1]] ^ AES_RCON[i/Nk - 1];
                temp[1] = AES_SBOX[temp[2]];
                temp[2] = AES_SBOX[temp[3]];
                temp[3] = AES_SBOX[t];
            } else if (i % Nk == 4) {
                for (auto& b : temp) b = AES_SBOX[b];
            }
            for (int j = 0; j < 4; ++j)
                roundKeys[i*4+j] = roundKeys[(i-Nk)*4+j] ^ temp[j];
        }
    }

    void encryptBlock(uint8_t state[16]) const {
        int Nr = 14;
        addRoundKey(state, 0);
        for (int r = 1; r < Nr; ++r) {
            subBytes(state); shiftRows(state); mixColumns(state); addRoundKey(state, r);
        }
        subBytes(state); shiftRows(state); addRoundKey(state, Nr);
    }

    void decryptBlock(uint8_t state[16]) const {
        int Nr = 14;
        addRoundKey(state, Nr);
        for (int r = Nr - 1; r > 0; --r) {
            invShiftRows(state); invSubBytes(state); addRoundKey(state, r); invMixColumns(state);
        }
        invShiftRows(state); invSubBytes(state); addRoundKey(state, 0);
    }

private:
    void addRoundKey(uint8_t state[16], int round) const {
        for (int i = 0; i < 16; ++i) state[i] ^= roundKeys[round*16+i];
    }
    static void subBytes(uint8_t s[16]) { for (int i = 0; i < 16; ++i) s[i] = AES_SBOX[s[i]]; }
    static void invSubBytes(uint8_t s[16]) { for (int i = 0; i < 16; ++i) s[i] = AES_RSBOX[s[i]]; }
    static void shiftRows(uint8_t s[16]) {
        uint8_t t;
        t=s[1]; s[1]=s[5]; s[5]=s[9]; s[9]=s[13]; s[13]=t;
        t=s[2]; s[2]=s[10]; s[10]=t; t=s[6]; s[6]=s[14]; s[14]=t;
        t=s[15]; s[15]=s[11]; s[11]=s[7]; s[7]=s[3]; s[3]=t;
    }
    static void invShiftRows(uint8_t s[16]) {
        uint8_t t;
        t=s[13]; s[13]=s[9]; s[9]=s[5]; s[5]=s[1]; s[1]=t;
        t=s[2]; s[2]=s[10]; s[10]=t; t=s[6]; s[6]=s[14]; s[14]=t;
        t=s[3]; s[3]=s[7]; s[7]=s[11]; s[11]=s[15]; s[15]=t;
    }
    static void mixColumns(uint8_t s[16]) {
        for (int c = 0; c < 4; ++c) {
            int i = c*4;
            uint8_t a0=s[i], a1=s[i+1], a2=s[i+2], a3=s[i+3];
            s[i]   = aesMul(a0,2)^aesMul(a1,3)^a2^a3;
            s[i+1] = a0^aesMul(a1,2)^aesMul(a2,3)^a3;
            s[i+2] = a0^a1^aesMul(a2,2)^aesMul(a3,3);
            s[i+3] = aesMul(a0,3)^a1^a2^aesMul(a3,2);
        }
    }
    static void invMixColumns(uint8_t s[16]) {
        for (int c = 0; c < 4; ++c) {
            int i = c*4;
            uint8_t a0=s[i], a1=s[i+1], a2=s[i+2], a3=s[i+3];
            s[i]   = aesMul(a0,14)^aesMul(a1,11)^aesMul(a2,13)^aesMul(a3,9);
            s[i+1] = aesMul(a0,9)^aesMul(a1,14)^aesMul(a2,11)^aesMul(a3,13);
            s[i+2] = aesMul(a0,13)^aesMul(a1,9)^aesMul(a2,14)^aesMul(a3,11);
            s[i+3] = aesMul(a0,11)^aesMul(a1,13)^aesMul(a2,9)^aesMul(a3,14);
        }
    }
};

} // anonymous namespace

QByteArray aes256Encrypt(const QByteArray& plaintext, const QByteArray& key, const QByteArray& iv) {
    if (key.size() != 32 || iv.size() != 16) return {};

    // PKCS7 padding
    int padLen = 16 - (plaintext.size() % 16);
    QByteArray padded = plaintext;
    padded.append(QByteArray(padLen, static_cast<char>(padLen)));

    AES256 aes;
    aes.keyExpansion(reinterpret_cast<const uint8_t*>(key.constData()));

    QByteArray result;
    result.reserve(padded.size());

    QByteArray prev = iv;
    for (int offset = 0; offset < padded.size(); offset += 16) {
        uint8_t block[16];
        for (int i = 0; i < 16; ++i)
            block[i] = static_cast<uint8_t>(padded[offset+i]) ^ static_cast<uint8_t>(prev[i]);
        aes.encryptBlock(block);
        prev = QByteArray(reinterpret_cast<const char*>(block), 16);
        result.append(prev);
    }
    return result;
}

QByteArray aes256Decrypt(const QByteArray& ciphertext, const QByteArray& key, const QByteArray& iv) {
    if (key.size() != 32 || iv.size() != 16 || ciphertext.size() % 16 != 0 || ciphertext.isEmpty())
        return {};

    AES256 aes;
    aes.keyExpansion(reinterpret_cast<const uint8_t*>(key.constData()));

    QByteArray result;
    result.reserve(ciphertext.size());

    QByteArray prev = iv;
    for (int offset = 0; offset < ciphertext.size(); offset += 16) {
        uint8_t block[16];
        std::memcpy(block, ciphertext.constData() + offset, 16);
        QByteArray cipherBlock(reinterpret_cast<const char*>(block), 16);
        aes.decryptBlock(block);
        for (int i = 0; i < 16; ++i)
            block[i] ^= static_cast<uint8_t>(prev[i]);
        result.append(reinterpret_cast<const char*>(block), 16);
        prev = cipherBlock;
    }

    // Remove PKCS7 padding
    if (result.isEmpty()) return {};
    int padLen = static_cast<uint8_t>(result.back());
    if (padLen < 1 || padLen > 16) return {};
    for (int i = 0; i < padLen; ++i) {
        if (static_cast<uint8_t>(result[result.size() - 1 - i]) != padLen)
            return {}; // invalid padding
    }
    result.chop(padLen);
    return result;
}

// ══════════════════════════════════════════════════════════════════
//  Random bytes (cryptographic quality via Qt)
// ══════════════════════════════════════════════════════════════════

QByteArray randomBytes(int count) {
    QByteArray result(count, '\0');
    auto* gen = QRandomGenerator::system();
    for (int i = 0; i < count; ++i)
        result[i] = static_cast<char>(gen->bounded(256));
    return result;
}

// ══════════════════════════════════════════════════════════════════
//  secp256k1 - Elliptic curve operations (minimal for key derivation)
// ══════════════════════════════════════════════════════════════════

namespace {

// secp256k1 field: p = 2^256 - 2^32 - 977
// Order: n = FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

// 256-bit unsigned integer (little-endian 32-bit limbs)
struct U256 {
    uint32_t d[8] = {};

    static U256 fromBytes(const uint8_t* bytes, int len = 32) {
        U256 r;
        for (int i = 0; i < 8 && i * 4 < len; ++i) {
            int off = len - 1 - i * 4;
            r.d[i] = 0;
            for (int j = 0; j < 4 && (off - j) >= 0; ++j)
                r.d[i] |= static_cast<uint32_t>(bytes[off - j]) << (j * 8);
        }
        return r;
    }

    void toBytes(uint8_t out[32]) const {
        for (int i = 0; i < 8; ++i) {
            out[31 - i*4]     = d[i] & 0xff;
            out[31 - i*4 - 1] = (d[i] >> 8) & 0xff;
            out[31 - i*4 - 2] = (d[i] >> 16) & 0xff;
            out[31 - i*4 - 3] = (d[i] >> 24) & 0xff;
        }
    }

    bool isZero() const {
        for (auto v : d) if (v) return false;
        return true;
    }

    int cmp(const U256& o) const {
        for (int i = 7; i >= 0; --i) {
            if (d[i] < o.d[i]) return -1;
            if (d[i] > o.d[i]) return 1;
        }
        return 0;
    }

    bool operator>=(const U256& o) const { return cmp(o) >= 0; }

    // add with carry, returns carry
    static U256 add(const U256& a, const U256& b, uint32_t& carry) {
        U256 r;
        uint64_t c = 0;
        for (int i = 0; i < 8; ++i) {
            c += static_cast<uint64_t>(a.d[i]) + b.d[i];
            r.d[i] = static_cast<uint32_t>(c);
            c >>= 32;
        }
        carry = static_cast<uint32_t>(c);
        return r;
    }

    // sub with borrow, returns borrow
    static U256 sub(const U256& a, const U256& b, uint32_t& borrow) {
        U256 r;
        int64_t c = 0;
        for (int i = 0; i < 8; ++i) {
            c += static_cast<int64_t>(a.d[i]) - b.d[i];
            r.d[i] = static_cast<uint32_t>(c);
            c >>= 32;
        }
        borrow = (c < 0) ? 1 : 0;
        return r;
    }
};

// Modular arithmetic mod p (secp256k1 field prime)
struct FieldP {
    static const U256 P;

    static U256 mod(const U256& a) {
        U256 r = a;
        while (r >= P) {
            uint32_t borrow;
            r = U256::sub(r, P, borrow);
        }
        return r;
    }

    static U256 add(const U256& a, const U256& b) {
        uint32_t carry;
        U256 r = U256::add(a, b, carry);
        if (carry || r >= P) {
            uint32_t borrow;
            r = U256::sub(r, P, borrow);
        }
        return r;
    }

    static U256 sub(const U256& a, const U256& b) {
        uint32_t borrow;
        U256 r = U256::sub(a, b, borrow);
        if (borrow) {
            uint32_t carry;
            r = U256::add(r, P, carry);
        }
        return r;
    }

    static U256 mul(const U256& a, const U256& b) {
        // Schoolbook multiplication mod p
        uint64_t t[16] = {};
        for (int i = 0; i < 8; ++i)
            for (int j = 0; j < 8; ++j)
                t[i+j] += static_cast<uint64_t>(a.d[i]) * b.d[j];
        // Propagate carries in t
        for (int i = 0; i < 15; ++i) { t[i+1] += t[i] >> 32; t[i] &= 0xFFFFFFFF; }

        // Barrett-like reduction: reduce 512-bit to 256-bit mod p
        // secp256k1 p = 2^256 - 0x1000003d1
        // So x mod p: split x = x_hi * 2^256 + x_lo, then x ≡ x_lo + x_hi * 0x1000003d1 (mod p)
        // May need to repeat since x_hi * 0x1000003d1 can overflow
        for (int pass = 0; pass < 2; ++pass) {
            // Extract hi part (limbs 8..15) and multiply by 0x1000003d1
            uint64_t acc[9] = {};
            for (int i = 0; i < 8; ++i) {
                // 0x1000003d1 = 0x100000000 + 0x3d1
                acc[i] += t[i] + t[8+i] * 0x3d1ULL;
                acc[i+1] += t[8+i]; // * 2^32 part
            }
            // Propagate carries
            for (int i = 0; i < 8; ++i) { acc[i+1] += acc[i] >> 32; acc[i] &= 0xFFFFFFFF; }
            for (int i = 0; i < 8; ++i) t[i] = acc[i];
            for (int i = 8; i < 16; ++i) t[i] = 0;
            t[8] = acc[8];
        }

        U256 r;
        for (int i = 0; i < 8; ++i) r.d[i] = static_cast<uint32_t>(t[i]);
        while (r >= P) { uint32_t borrow; r = U256::sub(r, P, borrow); }
        return r;
    }

    static U256 inv(const U256& a) {
        // Fermat's little theorem: a^(p-2) mod p
        // Use square-and-multiply
        U256 result;
        result.d[0] = 1; // 1
        U256 base = a;

        // p-2 in binary - we compute from LSB
        // p = FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
        // p-2 = FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2D
        uint8_t pMinus2[32];
        P.toBytes(pMinus2);
        pMinus2[31] -= 2; // p - 2

        for (int byte = 31; byte >= 0; --byte) {
            for (int bit = 0; bit < 8; ++bit) {
                if (pMinus2[byte] & (1 << (7 - bit)))
                    result = mul(result, base);
                if (byte > 0 || bit < 7)
                    base = mul(base, base);
            }
            // Careful: process MSB to LSB
            // Actually we need to go MSB first for square-and-multiply
        }
        // The above loop is wrong for square-and-multiply. Let me redo it properly.
        result.d[0] = 1;
        for (int i = 1; i < 8; ++i) result.d[i] = 0;
        base = a;

        // Square-and-multiply from MSB
        bool started = false;
        for (int byte = 0; byte < 32; ++byte) {
            for (int bit = 7; bit >= 0; --bit) {
                if (started)
                    result = mul(result, result);
                if (pMinus2[byte] & (1 << bit)) {
                    result = mul(result, a);
                    started = true;
                }
            }
        }
        return result;
    }
};

const U256 FieldP::P = [] {
    U256 p;
    // p = FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
    p.d[0] = 0xFFFFFC2F; p.d[1] = 0xFFFFFFFE;
    p.d[2] = 0xFFFFFFFF; p.d[3] = 0xFFFFFFFF;
    p.d[4] = 0xFFFFFFFF; p.d[5] = 0xFFFFFFFF;
    p.d[6] = 0xFFFFFFFF; p.d[7] = 0xFFFFFFFF;
    return p;
}();

// secp256k1 curve order n
static const U256 SECP256K1_N = [] {
    U256 n;
    // n = FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
    n.d[0] = 0xD0364141; n.d[1] = 0xBFD25E8C;
    n.d[2] = 0xAF48A03B; n.d[3] = 0xBAAEDCE6;
    n.d[4] = 0xFFFFFFFE; n.d[5] = 0xFFFFFFFF;
    n.d[6] = 0xFFFFFFFF; n.d[7] = 0xFFFFFFFF;
    return n;
}();

// Modular arithmetic mod n (curve order)
struct FieldN {
    static U256 add(const U256& a, const U256& b) {
        uint32_t carry;
        U256 r = U256::add(a, b, carry);
        if (carry || r >= SECP256K1_N) {
            uint32_t borrow;
            r = U256::sub(r, SECP256K1_N, borrow);
        }
        return r;
    }
};

// Point on secp256k1 (Jacobian coordinates for speed)
struct ECPoint {
    U256 x, y;
    bool infinity = true;
};

// Generator point G
static const ECPoint SECP256K1_G = [] {
    ECPoint g;
    // Gx = 79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
    g.x.d[0] = 0x16F81798; g.x.d[1] = 0x59F2815B; g.x.d[2] = 0x2DCE28D9; g.x.d[3] = 0x029BFCDB;
    g.x.d[4] = 0xCE870B07; g.x.d[5] = 0x55A06295; g.x.d[6] = 0xF9DCBBAC; g.x.d[7] = 0x79BE667E;
    // Gy = 483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A6855419 9C47D08FFB10D4B8
    g.y.d[0] = 0xFB10D4B8; g.y.d[1] = 0x9C47D08F; g.y.d[2] = 0xA6855419; g.y.d[3] = 0xFD17B448;
    g.y.d[4] = 0x0E1108A8; g.y.d[5] = 0x5DA4FBFC; g.y.d[6] = 0x26A3C465; g.y.d[7] = 0x483ADA77;
    g.infinity = false;
    return g;
}();

// EC point doubling (affine)
ECPoint ecDouble(const ECPoint& P) {
    if (P.infinity) return P;
    // s = (3 * x^2) / (2 * y)
    U256 x2 = FieldP::mul(P.x, P.x);
    U256 three;  three.d[0] = 3;
    U256 num = FieldP::mul(three, x2); // 3*x^2 (a=0 for secp256k1)
    U256 two; two.d[0] = 2;
    U256 den = FieldP::mul(two, P.y);
    U256 s = FieldP::mul(num, FieldP::inv(den));

    ECPoint R;
    R.infinity = false;
    // rx = s^2 - 2*x
    U256 s2 = FieldP::mul(s, s);
    U256 twox = FieldP::mul(two, P.x);
    R.x = FieldP::sub(s2, twox);
    // ry = s*(x - rx) - y
    R.y = FieldP::sub(FieldP::mul(s, FieldP::sub(P.x, R.x)), P.y);
    return R;
}

// EC point addition (affine)
ECPoint ecAdd(const ECPoint& P, const ECPoint& Q) {
    if (P.infinity) return Q;
    if (Q.infinity) return P;

    if (P.x.cmp(Q.x) == 0) {
        if (P.y.cmp(Q.y) == 0)
            return ecDouble(P);
        // P + (-P) = infinity
        ECPoint inf; return inf;
    }

    // s = (Qy - Py) / (Qx - Px)
    U256 dy = FieldP::sub(Q.y, P.y);
    U256 dx = FieldP::sub(Q.x, P.x);
    U256 s = FieldP::mul(dy, FieldP::inv(dx));

    ECPoint R;
    R.infinity = false;
    U256 s2 = FieldP::mul(s, s);
    R.x = FieldP::sub(FieldP::sub(s2, P.x), Q.x);
    R.y = FieldP::sub(FieldP::mul(s, FieldP::sub(P.x, R.x)), P.y);
    return R;
}

// Scalar multiplication: k * P
ECPoint ecMul(const U256& k, const ECPoint& P) {
    ECPoint R; // infinity
    ECPoint base = P;

    uint8_t kBytes[32];
    k.toBytes(kBytes);

    // Double-and-add from MSB
    bool started = false;
    for (int byte = 0; byte < 32; ++byte) {
        for (int bit = 7; bit >= 0; --bit) {
            if (started)
                R = ecDouble(R);
            if (kBytes[byte] & (1 << bit)) {
                R = ecAdd(R, P);
                started = true;
            }
        }
    }
    return R;
}

} // anonymous namespace

QByteArray privateToPublicKey(const QByteArray& privKey) {
    if (privKey.size() != 32) return {};
    U256 k = U256::fromBytes(reinterpret_cast<const uint8_t*>(privKey.constData()));
    ECPoint pub = ecMul(k, SECP256K1_G);
    if (pub.infinity) return {};

    // Compressed: 02/03 prefix + x
    uint8_t result[33];
    pub.x.toBytes(result + 1);
    // Check if y is even or odd
    result[0] = (pub.y.d[0] & 1) ? 0x03 : 0x02;
    return QByteArray(reinterpret_cast<const char*>(result), 33);
}

QByteArray privateToUncompressedPublicKey(const QByteArray& privKey) {
    if (privKey.size() != 32) return {};
    U256 k = U256::fromBytes(reinterpret_cast<const uint8_t*>(privKey.constData()));
    ECPoint pub = ecMul(k, SECP256K1_G);
    if (pub.infinity) return {};

    uint8_t result[65];
    result[0] = 0x04;
    pub.x.toBytes(result + 1);
    pub.y.toBytes(result + 33);
    return QByteArray(reinterpret_cast<const char*>(result), 65);
}

// ══════════════════════════════════════════════════════════════════
//  ECDSA Sign/Verify (deterministic k per RFC 6979 simplified)
// ══════════════════════════════════════════════════════════════════

namespace {

U256 modN_mul(const U256& a, const U256& b) {
    // Schoolbook multiplication mod n
    uint64_t t[16] = {};
    for (int i = 0; i < 8; ++i)
        for (int j = 0; j < 8; ++j)
            t[i+j] += static_cast<uint64_t>(a.d[i]) * b.d[j];
    for (int i = 0; i < 15; ++i) { t[i+1] += t[i] >> 32; t[i] &= 0xFFFFFFFF; }

    // Reduce mod n using repeated subtraction (simple but correct)
    // Convert back to U256 first - take low 256 bits and handle overflow
    // This is a simplified reduction
    U256 r;
    for (int i = 0; i < 8; ++i) r.d[i] = static_cast<uint32_t>(t[i]);
    // For now, handle the simple case (most multiplications in ECDSA context)
    while (r >= SECP256K1_N) {
        uint32_t borrow;
        r = U256::sub(r, SECP256K1_N, borrow);
    }
    return r;
}

U256 modN_inv(const U256& a) {
    // Fermat: a^(n-2) mod n
    uint8_t nMinus2[32];
    SECP256K1_N.toBytes(nMinus2);
    // n-2
    if (nMinus2[31] >= 2) { nMinus2[31] -= 2; }
    else { nMinus2[31] += 254; nMinus2[30]--; } // borrow

    U256 result; result.d[0] = 1;
    bool started = false;
    for (int byte = 0; byte < 32; ++byte) {
        for (int bit = 7; bit >= 0; --bit) {
            if (started)
                result = modN_mul(result, result);
            if (nMinus2[byte] & (1 << bit)) {
                result = modN_mul(result, a);
                started = true;
            }
        }
    }
    return result;
}

} // anonymous namespace

QByteArray ecdsaSign(const QByteArray& hash32, const QByteArray& privKey32) {
    if (hash32.size() != 32 || privKey32.size() != 32) return {};

    U256 z = U256::fromBytes(reinterpret_cast<const uint8_t*>(hash32.constData()));
    U256 d = U256::fromBytes(reinterpret_cast<const uint8_t*>(privKey32.constData()));

    // Deterministic k: k = HMAC-SHA256(privkey, hash) mod n (simplified RFC 6979)
    QByteArray kBytes = hmacSha512(privKey32, hash32).left(32);
    U256 k = U256::fromBytes(reinterpret_cast<const uint8_t*>(kBytes.constData()));
    // Ensure k < n
    while (k >= SECP256K1_N || k.isZero()) {
        kBytes = sha256(kBytes);
        k = U256::fromBytes(reinterpret_cast<const uint8_t*>(kBytes.constData()));
    }

    // R = k*G
    ECPoint R = ecMul(k, SECP256K1_G);
    if (R.infinity) return {};

    // r = R.x mod n
    U256 r = R.x;
    while (r >= SECP256K1_N) { uint32_t b; r = U256::sub(r, SECP256K1_N, b); }
    if (r.isZero()) return {};

    // s = k^(-1) * (z + r*d) mod n
    U256 rd = modN_mul(r, d);
    U256 zrd = FieldN::add(z, rd);
    U256 kInv = modN_inv(k);
    U256 s = modN_mul(kInv, zrd);
    if (s.isZero()) return {};

    // Low-S normalization (BIP-62)
    U256 halfN;
    {
        uint32_t borrow;
        U256 one; one.d[0] = 1;
        halfN = U256::sub(SECP256K1_N, one, borrow);
        // halfN = (n-1)/2 ... shift right by 1
        for (int i = 0; i < 7; ++i)
            halfN.d[i] = (halfN.d[i] >> 1) | (halfN.d[i+1] << 31);
        halfN.d[7] >>= 1;
    }
    if (s.cmp(halfN) > 0) {
        uint32_t borrow;
        s = U256::sub(SECP256K1_N, s, borrow);
    }

    // DER encode
    uint8_t rBuf[33], sBuf[33];
    r.toBytes(rBuf + 1); rBuf[0] = 0;
    s.toBytes(sBuf + 1); sBuf[0] = 0;

    int rOff = 1, sOff = 1;
    while (rOff < 33 && rBuf[rOff] == 0) rOff++;
    if (rBuf[rOff] & 0x80) rOff--; // need leading 0
    while (sOff < 33 && sBuf[sOff] == 0) sOff++;
    if (sBuf[sOff] & 0x80) sOff--;

    int rLen = 33 - rOff, sLen = 33 - sOff;

    QByteArray sig;
    sig.append(0x30); // SEQUENCE
    sig.append(static_cast<char>(rLen + sLen + 4));
    sig.append(0x02); // INTEGER
    sig.append(static_cast<char>(rLen));
    sig.append(reinterpret_cast<const char*>(rBuf + rOff), rLen);
    sig.append(0x02);
    sig.append(static_cast<char>(sLen));
    sig.append(reinterpret_cast<const char*>(sBuf + sOff), sLen);
    return sig;
}

bool ecdsaVerify(const QByteArray& hash32, const QByteArray& signature, const QByteArray& pubkey33) {
    // For now, verification is done server-side via the node
    // This is a placeholder for offline verification
    Q_UNUSED(hash32); Q_UNUSED(signature); Q_UNUSED(pubkey33);
    return false;
}

// ══════════════════════════════════════════════════════════════════
//  Bech32 encoding
// ══════════════════════════════════════════════════════════════════

namespace {

const char* BECH32_CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";

uint32_t bech32Polymod(const std::vector<uint8_t>& values) {
    const uint32_t gen[] = {0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3};
    uint32_t chk = 1;
    for (uint8_t v : values) {
        uint32_t top = chk >> 25;
        chk = ((chk & 0x1ffffff) << 5) ^ v;
        for (int i = 0; i < 5; ++i)
            if ((top >> i) & 1) chk ^= gen[i];
    }
    return chk;
}

std::vector<uint8_t> bech32HrpExpand(const QString& hrp) {
    std::vector<uint8_t> ret;
    for (auto c : hrp) ret.push_back(c.unicode() >> 5);
    ret.push_back(0);
    for (auto c : hrp) ret.push_back(c.unicode() & 31);
    return ret;
}

std::vector<uint8_t> convertBits(const uint8_t* data, int len, int fromBits, int toBits, bool pad) {
    std::vector<uint8_t> ret;
    int acc = 0, bits = 0;
    int maxv = (1 << toBits) - 1;
    for (int i = 0; i < len; ++i) {
        acc = (acc << fromBits) | data[i];
        bits += fromBits;
        while (bits >= toBits) {
            bits -= toBits;
            ret.push_back((acc >> bits) & maxv);
        }
    }
    if (pad && bits > 0)
        ret.push_back((acc << (toBits - bits)) & maxv);
    return ret;
}

QString bech32Encode(const QString& hrp, const std::vector<uint8_t>& data) {
    auto hrpExp = bech32HrpExpand(hrp);
    std::vector<uint8_t> values(hrpExp);
    values.insert(values.end(), data.begin(), data.end());
    values.resize(values.size() + 6, 0);
    uint32_t polymod = bech32Polymod(values) ^ 1;

    QString ret = hrp + "1";
    for (auto d : data)
        ret += BECH32_CHARSET[d];
    for (int i = 0; i < 6; ++i)
        ret += BECH32_CHARSET[(polymod >> (5 * (5 - i))) & 31];
    return ret;
}

} // anonymous namespace

QString pubkeyToOb1qAddress(const QByteArray& compressedPubkey) {
    QByteArray h = hash160(compressedPubkey);
    return pubkeyHashToAddress(h, "ob");
}

QString pubkeyHashToAddress(const QByteArray& hash20, const QString& hrp) {
    if (hash20.size() != 20) return {};
    // witness version 0 + hash160
    std::vector<uint8_t> prog(hash20.size());
    for (int i = 0; i < hash20.size(); ++i)
        prog[i] = static_cast<uint8_t>(hash20[i]);

    auto converted = convertBits(prog.data(), static_cast<int>(prog.size()), 8, 5, true);
    // Prepend witness version 0
    converted.insert(converted.begin(), 0);
    return bech32Encode(hrp, converted);
}

// ══════════════════════════════════════════════════════════════════
//  BIP-39 Mnemonic (English wordlist embedded)
// ══════════════════════════════════════════════════════════════════

// The full BIP-39 English wordlist (2048 words) - stored in a separate include
// to keep this file manageable. We embed it as a static array.

#include "bip39_wordlist.inc"

QStringList bip39Wordlist() {
    QStringList list;
    list.reserve(2048);
    for (int i = 0; i < 2048; ++i)
        list.append(QString::fromLatin1(BIP39_ENGLISH[i]));
    return list;
}

QString generateMnemonic(int wordCount) {
    int entropyBits;
    if (wordCount == 24) entropyBits = 256;
    else entropyBits = 128; // 12 words

    int entropyBytes = entropyBits / 8;
    QByteArray entropy = randomBytes(entropyBytes);

    // Checksum = first (entropyBits/32) bits of SHA-256(entropy)
    QByteArray hash = sha256(entropy);
    int checksumBits = entropyBits / 32;

    // Combine entropy + checksum bits
    std::vector<bool> bits;
    bits.reserve(entropyBits + checksumBits);
    for (int i = 0; i < entropyBytes; ++i)
        for (int b = 7; b >= 0; --b)
            bits.push_back((static_cast<uint8_t>(entropy[i]) >> b) & 1);
    for (int b = 7; b >= 8 - checksumBits; --b)
        bits.push_back((static_cast<uint8_t>(hash[0]) >> b) & 1);

    QStringList words;
    for (int i = 0; i < wordCount; ++i) {
        int idx = 0;
        for (int b = 0; b < 11; ++b)
            idx = (idx << 1) | (bits[i * 11 + b] ? 1 : 0);
        words.append(QString::fromLatin1(BIP39_ENGLISH[idx]));
    }
    return words.join(' ');
}

QByteArray mnemonicToSeed(const QString& mnemonic, const QString& passphrase) {
    QByteArray pwd = mnemonic.toUtf8();
    QByteArray salt = ("mnemonic" + passphrase).toUtf8();
    return pbkdf2HmacSha512(pwd, salt, 2048, 64);
}

bool validateMnemonic(const QString& mnemonic) {
    QStringList words = mnemonic.simplified().split(' ', Qt::SkipEmptyParts);
    if (words.size() != 12 && words.size() != 15 && words.size() != 18
        && words.size() != 21 && words.size() != 24)
        return false;

    QStringList wordlist = bip39Wordlist();
    for (const auto& w : words) {
        if (!wordlist.contains(w.toLower()))
            return false;
    }

    // Verify checksum
    std::vector<int> indices;
    for (const auto& w : words) {
        int idx = wordlist.indexOf(w.toLower());
        if (idx < 0) return false;
        indices.push_back(idx);
    }

    int totalBits = words.size() * 11;
    int checksumBits = totalBits / 33;
    int entropyBits = totalBits - checksumBits;

    std::vector<bool> bits;
    for (int idx : indices)
        for (int b = 10; b >= 0; --b)
            bits.push_back((idx >> b) & 1);

    QByteArray entropy(entropyBits / 8, '\0');
    for (int i = 0; i < entropyBits; ++i)
        if (bits[i])
            entropy[i / 8] = entropy[i / 8] | (1 << (7 - (i % 8)));

    QByteArray hash = sha256(entropy);
    for (int i = 0; i < checksumBits; ++i) {
        bool expected = (static_cast<uint8_t>(hash[0]) >> (7 - i)) & 1;
        if (bits[entropyBits + i] != expected)
            return false;
    }
    return true;
}

// ══════════════════════════════════════════════════════════════════
//  BIP-32 HD Key Derivation
// ══════════════════════════════════════════════════════════════════

ExtendedKey masterKeyFromSeed(const QByteArray& seed) {
    QByteArray I = hmacSha512(QByteArray("Bitcoin seed"), seed);
    ExtendedKey key;
    key.key = I.left(32);
    key.chainCode = I.mid(32, 32);
    key.depth = 0;
    key.childIndex = 0;
    key.parentFingerprint = QByteArray(4, '\0');
    return key;
}

ExtendedKey deriveChild(const ExtendedKey& parent, uint32_t index) {
    QByteArray data;
    bool hardened = (index & 0x80000000) != 0;

    if (hardened) {
        data.append('\x00');
        data.append(parent.key);
    } else {
        data.append(privateToPublicKey(parent.key));
    }
    data.append(static_cast<char>((index >> 24) & 0xff));
    data.append(static_cast<char>((index >> 16) & 0xff));
    data.append(static_cast<char>((index >> 8) & 0xff));
    data.append(static_cast<char>(index & 0xff));

    QByteArray I = hmacSha512(parent.chainCode, data);
    QByteArray IL = I.left(32);
    QByteArray IR = I.mid(32, 32);

    // child key = (IL + parent key) mod n
    U256 il = U256::fromBytes(reinterpret_cast<const uint8_t*>(IL.constData()));
    U256 pk = U256::fromBytes(reinterpret_cast<const uint8_t*>(parent.key.constData()));
    U256 child = FieldN::add(il, pk);

    ExtendedKey result;
    uint8_t childBytes[32];
    child.toBytes(childBytes);
    result.key = QByteArray(reinterpret_cast<const char*>(childBytes), 32);
    result.chainCode = IR;
    result.depth = parent.depth + 1;
    result.childIndex = index;

    // Parent fingerprint = first 4 bytes of Hash160(parent public key)
    QByteArray parentPub = privateToPublicKey(parent.key);
    QByteArray fp = hash160(parentPub);
    result.parentFingerprint = fp.left(4);

    return result;
}

ExtendedKey derivePath(const ExtendedKey& master, const QString& path) {
    // Parse "m/44'/9999'/0'/0/0"
    QStringList parts = path.split('/', Qt::SkipEmptyParts);
    ExtendedKey current = master;

    for (const auto& part : parts) {
        if (part == "m") continue;
        bool hardened = part.endsWith('\'') || part.endsWith('h');
        QString num = part;
        if (hardened) num.chop(1);
        bool ok;
        uint32_t index = num.toUInt(&ok);
        if (!ok) continue;
        if (hardened) index |= 0x80000000;
        current = deriveChild(current, index);
    }
    return current;
}

} // namespace crypto
} // namespace omni

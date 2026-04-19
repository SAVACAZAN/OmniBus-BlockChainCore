#include "widgets/QRCodeWidget.h"
#include <QPainter>
#include <QPainterPath>
#include <cstring>
#include <cmath>
#include <vector>
#include <algorithm>

namespace omni {

// ────────────────────────────────────────────────────────────────────────────
// Minimal QR Code encoder — Version 1-4, Error Correction L, Byte mode
// Sufficient for ob1q... addresses (~42 chars) and typical short strings.
// This is a simplified but functional QR encoder.
// ────────────────────────────────────────────────────────────────────────────

namespace qr {

// Capacity (byte mode, EC level L): V1=17, V2=32, V3=53, V4=78
static constexpr int CAPACITIES[] = {0, 17, 32, 53, 78};
static constexpr int SIZES[] = {0, 21, 25, 29, 33};

// Number of EC codewords per block (L level)
static constexpr int EC_CODEWORDS[] = {0, 7, 10, 15, 20};
// Number of data codewords
static constexpr int DATA_CODEWORDS[] = {0, 19, 34, 55, 80};

// Alignment pattern positions for V2-V4
static constexpr int ALIGN_POS[][2] = {{0,0}, {0,0}, {6,18}, {6,22}, {6,26}};

// GF(256) arithmetic for Reed-Solomon
static uint8_t gf_exp[512];
static uint8_t gf_log[256];
static bool gf_inited = false;

static void gf_init() {
    if (gf_inited) return;
    gf_inited = true;
    int x = 1;
    for (int i = 0; i < 255; i++) {
        gf_exp[i] = (uint8_t)x;
        gf_log[x] = (uint8_t)i;
        x <<= 1;
        if (x & 0x100) x ^= 0x11d;
    }
    for (int i = 255; i < 512; i++)
        gf_exp[i] = gf_exp[i - 255];
}

static uint8_t gf_mul(uint8_t a, uint8_t b) {
    if (a == 0 || b == 0) return 0;
    return gf_exp[gf_log[a] + gf_log[b]];
}

static std::vector<uint8_t> rs_encode(const std::vector<uint8_t>& data, int nsym) {
    gf_init();
    // Build generator polynomial
    std::vector<uint8_t> gen(nsym + 1, 0);
    gen[0] = 1;
    for (int i = 0; i < nsym; i++) {
        for (int j = nsym; j > 0; j--) {
            gen[j] = gen[j - 1] ^ gf_mul(gen[j], gf_exp[i]);
        }
        gen[0] = gf_mul(gen[0], gf_exp[i]);
    }

    std::vector<uint8_t> remainder(nsym, 0);
    for (size_t i = 0; i < data.size(); i++) {
        uint8_t coef = data[i] ^ remainder[0];
        std::rotate(remainder.begin(), remainder.begin() + 1, remainder.end());
        remainder[nsym - 1] = 0;
        if (coef != 0) {
            for (int j = 0; j < nsym; j++)
                remainder[j] ^= gf_mul(gen[nsym - 1 - j], coef);
        }
    }
    return remainder;
}

struct QRMatrix {
    int size;
    std::vector<std::vector<bool>> modules;
    std::vector<std::vector<bool>> isFunction;

    QRMatrix(int sz) : size(sz), modules(sz, std::vector<bool>(sz, false)),
                        isFunction(sz, std::vector<bool>(sz, false)) {}

    void setModule(int r, int c, bool black, bool func = true) {
        if (r >= 0 && r < size && c >= 0 && c < size) {
            modules[r][c] = black;
            if (func) isFunction[r][c] = true;
        }
    }

    void addFinderPattern(int row, int col) {
        for (int r = -1; r <= 7; r++) {
            for (int c = -1; c <= 7; c++) {
                int rr = row + r, cc = col + c;
                if (rr < 0 || rr >= size || cc < 0 || cc >= size) continue;
                bool black = (r >= 0 && r <= 6 && (c == 0 || c == 6)) ||
                             (c >= 0 && c <= 6 && (r == 0 || r == 6)) ||
                             (r >= 2 && r <= 4 && c >= 2 && c <= 4);
                setModule(rr, cc, black);
            }
        }
    }

    void addAlignmentPattern(int row, int col) {
        for (int r = -2; r <= 2; r++) {
            for (int c = -2; c <= 2; c++) {
                bool black = std::max(std::abs(r), std::abs(c)) != 1;
                setModule(row + r, col + c, black);
            }
        }
    }

    void addTimingPatterns() {
        for (int i = 8; i < size - 8; i++) {
            setModule(6, i, i % 2 == 0);
            setModule(i, 6, i % 2 == 0);
        }
    }

    void reserveFormatInfo() {
        for (int i = 0; i < 8; i++) {
            setModule(8, i, false);
            setModule(i, 8, false);
            setModule(8, size - 1 - i, false);
            setModule(size - 1 - i, 8, false);
        }
        setModule(8, 8, false);
        setModule(size - 8, 8, true); // dark module
    }

    void placeData(const std::vector<uint8_t>& data) {
        int bitIdx = 0;
        int totalBits = (int)data.size() * 8;

        for (int right = size - 1; right >= 1; right -= 2) {
            if (right == 6) right = 5; // skip timing column
            for (int vert = 0; vert < size; vert++) {
                for (int j = 0; j < 2; j++) {
                    int col = right - j;
                    bool upward = ((right + 1) / 2) % 2 == 0;
                    int row = upward ? vert : (size - 1 - vert);

                    if (isFunction[row][col]) continue;

                    bool black = false;
                    if (bitIdx < totalBits) {
                        black = ((data[bitIdx / 8] >> (7 - (bitIdx % 8))) & 1) != 0;
                        bitIdx++;
                    }
                    modules[row][col] = black;
                }
            }
        }
    }

    void applyMask0() {
        for (int r = 0; r < size; r++) {
            for (int c = 0; c < size; c++) {
                if (!isFunction[r][c] && (r + c) % 2 == 0)
                    modules[r][c] = !modules[r][c];
            }
        }
    }

    void writeFormatInfo() {
        // Format info for EC level L (01) and mask 0 (000) = 01000
        // Pre-computed with BCH: 0x77C4 → bits: 111011111000100
        uint32_t bits = 0x77C4;

        for (int i = 0; i < 6; i++) setModule(8, i, (bits >> (14 - i)) & 1);
        setModule(8, 7, (bits >> 8) & 1);
        setModule(8, 8, (bits >> 7) & 1);
        setModule(7, 8, (bits >> 6) & 1);
        for (int i = 0; i < 6; i++) setModule(5 - i, 8, (bits >> (i)) & 1);

        for (int i = 0; i < 8; i++)
            setModule(8, size - 1 - i, (bits >> (14 - i)) & 1);
        for (int i = 0; i < 7; i++)
            setModule(size - 7 + i, 8, (bits >> (i)) & 1);
    }
};

} // namespace qr

QRCodeWidget::QRCodeWidget(QWidget* parent)
    : QWidget(parent)
{
    setMinimumSize(160, 160);
}

void QRCodeWidget::setData(const QString& data) {
    m_data = data;
    generateQR();
    update();
}

void QRCodeWidget::generateQR() {
    m_modules.clear();
    m_size = 0;
    if (m_data.isEmpty()) return;

    QByteArray bytes = m_data.toUtf8();
    int len = bytes.size();

    // Find minimum version
    int version = 0;
    for (int v = 1; v <= 4; v++) {
        if (len <= qr::CAPACITIES[v]) { version = v; break; }
    }
    if (version == 0) return; // too long

    m_size = qr::SIZES[version];

    // Build data codewords: [mode=0100(byte)][count][data][terminator][padding]
    int totalDataCW = qr::DATA_CODEWORDS[version];
    int totalBits = totalDataCW * 8;

    std::vector<bool> bits;
    auto addBits = [&](uint32_t val, int count) {
        for (int i = count - 1; i >= 0; i--)
            bits.push_back((val >> i) & 1);
    };

    addBits(0b0100, 4); // byte mode indicator
    int countBits = (version <= 1) ? 8 : 16; // V1=8bit count, V2+=16bit
    // Actually for V1-9 byte mode, count is always 8 bits
    addBits(len, 8);

    for (int i = 0; i < len; i++)
        addBits((uint8_t)bytes[i], 8);

    // Terminator
    int remaining = totalBits - (int)bits.size();
    int termLen = std::min(4, remaining);
    addBits(0, termLen);

    // Pad to byte boundary
    while (bits.size() % 8 != 0) bits.push_back(false);

    // Pad codewords
    uint8_t padBytes[] = {0xEC, 0x11};
    int padIdx = 0;
    while ((int)bits.size() < totalBits) {
        addBits(padBytes[padIdx], 8);
        padIdx = (padIdx + 1) % 2;
    }

    // Convert to bytes
    std::vector<uint8_t> dataCW(totalDataCW);
    for (int i = 0; i < totalDataCW; i++) {
        uint8_t b = 0;
        for (int j = 0; j < 8; j++)
            b = (b << 1) | (bits[i * 8 + j] ? 1 : 0);
        dataCW[i] = b;
    }

    // Reed-Solomon EC
    int ecCW = qr::EC_CODEWORDS[version];
    auto ecBytes = qr::rs_encode(dataCW, ecCW);

    // Interleave (single block for V1-4 L)
    std::vector<uint8_t> payload;
    payload.insert(payload.end(), dataCW.begin(), dataCW.end());
    payload.insert(payload.end(), ecBytes.begin(), ecBytes.end());

    // Build matrix
    qr::QRMatrix mat(m_size);
    mat.addFinderPattern(0, 0);
    mat.addFinderPattern(0, m_size - 7);
    mat.addFinderPattern(m_size - 7, 0);
    mat.addTimingPatterns();

    if (version >= 2) {
        int pos = qr::ALIGN_POS[version][1];
        mat.addAlignmentPattern(pos, pos);
    }

    mat.reserveFormatInfo();
    mat.placeData(payload);
    mat.applyMask0();
    mat.writeFormatInfo();

    // Copy to Qt data
    m_modules.resize(m_size);
    for (int r = 0; r < m_size; r++) {
        m_modules[r].resize(m_size);
        for (int c = 0; c < m_size; c++)
            m_modules[r][c] = mat.modules[r][c];
    }
}

void QRCodeWidget::paintEvent(QPaintEvent*) {
    if (m_size == 0) return;

    QPainter p(this);
    p.setRenderHint(QPainter::Antialiasing);

    int side = qMin(width(), height());
    int quietZone = 4; // modules of quiet zone
    int totalModules = m_size + 2 * quietZone;
    double moduleSize = (double)side / totalModules;

    // Center
    double ox = (width() - side) / 2.0;
    double oy = (height() - side) / 2.0;

    // White background with rounded corners
    QPainterPath path;
    path.addRoundedRect(QRectF(ox, oy, side, side), 8, 8);
    p.fillPath(path, Qt::white);

    // Draw modules
    p.setPen(Qt::NoPen);
    p.setBrush(Qt::black);

    for (int r = 0; r < m_size; r++) {
        for (int c = 0; c < m_size; c++) {
            if (m_modules[r][c]) {
                double x = ox + (c + quietZone) * moduleSize;
                double y = oy + (r + quietZone) * moduleSize;
                p.drawRect(QRectF(x, y, moduleSize + 0.5, moduleSize + 0.5));
            }
        }
    }
}

} // namespace omni

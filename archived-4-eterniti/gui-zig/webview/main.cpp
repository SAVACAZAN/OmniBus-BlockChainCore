// OmniBus Wallet — WebView2 GUI with Encrypted Vault
// DPAPI-encrypted vault for API keys (same approach as OmnibusSidebar SuperVault)

#define _CRT_SECURE_NO_WARNINGS
#define WEBVIEW_STATIC
#define WEBVIEW_MSEDGE
#include <webview/webview.h>
#include <windows.h>
#include <wincrypt.h>
#include <shlobj.h>
#include <string>
#include <cstdio>
#include <vector>
#include <sstream>

#pragma comment(lib, "crypt32.lib")

// ═══════════════════════════════════════════════════════════════
//  Vault: DPAPI-encrypted API key storage
// ═══════════════════════════════════════════════════════════════

static const char VAULT_MAGIC[4] = { 'O', 'B', 'V', '2' }; // OmniBus Vault v2
static const uint32_t VAULT_VERSION = 2;

static std::string getVaultPath() {
    char appdata[MAX_PATH];
    if (SUCCEEDED(SHGetFolderPathA(NULL, CSIDL_APPDATA, NULL, 0, appdata))) {
        std::string dir = std::string(appdata) + "\\OmniBus\\OmniBus-Qt";
        CreateDirectoryA((std::string(appdata) + "\\OmniBus").c_str(), NULL);
        CreateDirectoryA(dir.c_str(), NULL);
        return dir + "\\api_vault.dat";
    }
    return "api_vault.dat";
}

// DPAPI encrypt
static std::vector<uint8_t> dpapiEncrypt(const std::vector<uint8_t>& plain) {
    DATA_BLOB in_blob, out_blob;
    in_blob.pbData = const_cast<BYTE*>(plain.data());
    in_blob.cbData = (DWORD)plain.size();
    if (!CryptProtectData(&in_blob, L"OmniBusVault", NULL, NULL, NULL, 0, &out_blob))
        return {};
    std::vector<uint8_t> result(out_blob.pbData, out_blob.pbData + out_blob.cbData);
    LocalFree(out_blob.pbData);
    return result;
}

// DPAPI decrypt
static std::vector<uint8_t> dpapiDecrypt(const std::vector<uint8_t>& cipher) {
    DATA_BLOB in_blob, out_blob;
    in_blob.pbData = const_cast<BYTE*>(cipher.data());
    in_blob.cbData = (DWORD)cipher.size();
    if (!CryptUnprotectData(&in_blob, NULL, NULL, NULL, NULL, 0, &out_blob))
        return {};
    std::vector<uint8_t> result(out_blob.pbData, out_blob.pbData + out_blob.cbData);
    SecureZeroMemory(out_blob.pbData, out_blob.cbData);
    LocalFree(out_blob.pbData);
    return result;
}

// Serialize string: [4-byte len][data]
static void writeStr(std::vector<uint8_t>& buf, const std::string& s) {
    uint32_t len = (uint32_t)s.size();
    buf.insert(buf.end(), (uint8_t*)&len, (uint8_t*)&len + 4);
    buf.insert(buf.end(), s.begin(), s.end());
}

static std::string readStr(const uint8_t*& ptr, const uint8_t* end) {
    if (ptr + 4 > end) return "";
    uint32_t len = *(uint32_t*)ptr; ptr += 4;
    if (ptr + len > end || len > 65536) return "";
    std::string s((char*)ptr, len); ptr += len;
    return s;
}

// Save vault JSON as DPAPI-encrypted file
static bool saveVault(const std::string& json) {
    std::vector<uint8_t> plain;
    // Header
    plain.insert(plain.end(), VAULT_MAGIC, VAULT_MAGIC + 4);
    uint32_t ver = VAULT_VERSION;
    plain.insert(plain.end(), (uint8_t*)&ver, (uint8_t*)&ver + 4);
    // JSON payload
    writeStr(plain, json);

    auto encrypted = dpapiEncrypt(plain);
    SecureZeroMemory(plain.data(), plain.size());
    if (encrypted.empty()) return false;

    std::string path = getVaultPath();
    FILE* f = fopen(path.c_str(), "wb");
    if (!f) return false;
    fwrite(encrypted.data(), 1, encrypted.size(), f);
    fclose(f);
    return true;
}

// Load vault: read file, DPAPI decrypt, return JSON
static std::string loadVault() {
    std::string path = getVaultPath();
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) return "[]";
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz <= 0 || sz > 10*1024*1024) { fclose(f); return "[]"; }
    std::vector<uint8_t> cipher(sz);
    fread(cipher.data(), 1, sz, f);
    fclose(f);

    auto plain = dpapiDecrypt(cipher);
    if (plain.size() < 12) return "[]"; // magic(4) + version(4) + len(4) min

    // Verify magic
    if (memcmp(plain.data(), VAULT_MAGIC, 4) != 0) {
        SecureZeroMemory(plain.data(), plain.size());
        return "[]";
    }

    const uint8_t* ptr = plain.data() + 8; // skip magic + version
    const uint8_t* end = plain.data() + plain.size();
    std::string json = readStr(ptr, end);
    SecureZeroMemory(plain.data(), plain.size());
    return json;
}

// ═══════════════════════════════════════════════════════════════
//  HTML loader
// ═══════════════════════════════════════════════════════════════

static std::string loadHtmlFile() {
    char path[MAX_PATH];
    GetModuleFileNameA(nullptr, path, MAX_PATH);
    std::string dir(path);
    dir = dir.substr(0, dir.find_last_of("\\/") + 1);
    dir += "ui.html";

    FILE* f = fopen(dir.c_str(), "rb");
    if (f) {
        fseek(f, 0, SEEK_END);
        long sz = ftell(f);
        fseek(f, 0, SEEK_SET);
        std::string html(sz, '\0');
        fread(&html[0], 1, sz, f);
        fclose(f);
        return html;
    }
    return "<html><body style='background:#11131f;color:#e0e0f0;font-family:Segoe UI;padding:40px;'>"
           "<h1 style='color:#00b3a4'>OmniBus Wallet</h1>"
           "<p>Error: ui.html not found</p></body></html>";
}

// ═══════════════════════════════════════════════════════════════
//  WebView2 bindings (JS ↔ C++)
// ═══════════════════════════════════════════════════════════════

int WINAPI WinMain(HINSTANCE, HINSTANCE, LPSTR, int) {
    webview_t w = webview_create(1, nullptr);
    if (!w) return 1;

    // Bind: vault_load() → returns JSON array of API keys
    webview_bind(w, "vault_load",
        [](const char* id, const char* req, void* arg) {
            webview_t wv = (webview_t)arg;
            std::string json = loadVault();
            // Escape for JSON string return
            std::string escaped = "\"";
            for (char c : json) {
                if (c == '"') escaped += "\\\"";
                else if (c == '\\') escaped += "\\\\";
                else if (c == '\n') escaped += "\\n";
                else escaped += c;
            }
            escaped += "\"";
            webview_return(wv, id, 0, escaped.c_str());
        }, w);

    // Bind: vault_save(json_string) → saves encrypted
    webview_bind(w, "vault_save",
        [](const char* id, const char* req, void* arg) {
            webview_t wv = (webview_t)arg;
            // req is JSON array of arguments: ["json_string"]
            std::string r(req);
            // Extract first argument (the JSON string)
            // Format: ["escaped_json_content"]
            size_t first_quote = r.find('"');
            size_t last_quote = r.rfind('"');
            std::string json_escaped;
            if (first_quote != std::string::npos && last_quote > first_quote) {
                json_escaped = r.substr(first_quote + 1, last_quote - first_quote - 1);
            }
            // Unescape
            std::string json;
            for (size_t i = 0; i < json_escaped.size(); i++) {
                if (json_escaped[i] == '\\' && i + 1 < json_escaped.size()) {
                    char next = json_escaped[i+1];
                    if (next == '"') { json += '"'; i++; }
                    else if (next == '\\') { json += '\\'; i++; }
                    else if (next == 'n') { json += '\n'; i++; }
                    else json += json_escaped[i];
                } else {
                    json += json_escaped[i];
                }
            }
            bool ok = saveVault(json);
            webview_return(wv, id, 0, ok ? "true" : "false");
        }, w);

    // Bind: vault_path() → returns vault file path
    webview_bind(w, "vault_path",
        [](const char* id, const char* req, void* arg) {
            webview_t wv = (webview_t)arg;
            std::string path = getVaultPath();
            std::string escaped = "\"";
            for (char c : path) {
                if (c == '\\') escaped += "\\\\";
                else escaped += c;
            }
            escaped += "\"";
            webview_return(wv, id, 0, escaped.c_str());
        }, w);

    std::string html = loadHtmlFile();
    webview_set_title(w, "OmniBus Wallet \xe2\x80\x94 WebView2");
    webview_set_size(w, 1280, 800, WEBVIEW_HINT_NONE);
    webview_set_html(w, html.c_str());
    webview_run(w);
    webview_destroy(w);
    return 0;
}

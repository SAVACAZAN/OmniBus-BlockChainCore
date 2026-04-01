/* ============================================================
 *  omnibus_vault.h  --  C API for Ada SPARK Vault Library
 *
 *  This header is used by Qt6 C++ GUI to call SPARK-verified
 *  vault operations compiled in omnibus_vault.dll.
 *
 *  All crypto operations (DPAPI encrypt/decrypt, secure wipe)
 *  run through SPARK-proven Ada code.
 * ============================================================ */

#ifndef OMNIBUS_VAULT_H
#define OMNIBUS_VAULT_H

#ifdef __cplusplus
extern "C" {
#endif

/* ── Return codes ───────────────────────────────────────────── */
#define VAULT_OK         0
#define VAULT_ERR       -1
#define VAULT_NOT_FOUND -2
#define VAULT_LOCKED    -3
#define VAULT_FULL      -4

/* ── Exchange IDs ───────────────────────────────────────────── */
#define VAULT_EX_LCX      0
#define VAULT_EX_KRAKEN   1
#define VAULT_EX_COINBASE 2
#define VAULT_EX_COUNT    3

/* ── Key status ─────────────────────────────────────────────── */
#define VAULT_STATUS_FREE     0
#define VAULT_STATUS_PAID     1
#define VAULT_STATUS_NOT_PAID 2

/* ── Lifecycle ──────────────────────────────────────────────── */

/** Initialize Ada runtime + vault. Call once at startup. */
void vault_lib_init(void);

/** Load vault from disk (or create empty). */
int vault_init(void);

/** Lock vault: wipe all keys from memory. */
int vault_lock(void);

/** Save vault to DPAPI-encrypted file. */
int vault_save(void);

/** Returns 1 if vault is loaded/unlocked. */
int vault_is_loaded(void);

/* ── Key management ─────────────────────────────────────────── */

int vault_add_key(int exchange, const char* name,
                  const char* api_key, const char* secret,
                  int status);

int vault_delete_key(int exchange, int slot);

int vault_update_key(int exchange, int slot,
                     const char* name, const char* api_key,
                     const char* secret, int status);

int vault_set_status(int exchange, int slot, int status);

/* ── Queries ────────────────────────────────────────────────── */

int vault_key_count(int exchange);
int vault_has_keys(int exchange);

/** Get key info. name_buf/key_buf are filled (null-terminated).
 *  API key is MASKED (first 6 + last 4 chars).
 *  Secret is NOT returned here (use vault_get_secret). */
int vault_get_key(int exchange, int slot,
                  char* name_buf, int name_cap,
                  char* key_buf, int key_cap,
                  int* status_out, int* in_use_out);

/** Get full API secret (caller must vault_wipe after use). */
int vault_get_secret(int exchange, int slot,
                     char* sec_buf, int sec_cap);

/* ── DPAPI direct ───────────────────────────────────────────── */

int vault_encrypt(const char* plain, int plain_len,
                  char* cipher, int cipher_cap, int* out_len);

int vault_decrypt(const char* cipher, int cipher_len,
                  char* plain, int plain_cap, int* out_len);

/* ── Secure wipe ────────────────────────────────────────────── */

/** Overwrite buffer with zeros (guaranteed not optimized out). */
void vault_wipe(char* buf, int len);

/* ── Info ────────────────────────────────────────────────────── */

/** Returns vault file path (static string, do NOT free). */
const char* vault_get_path(void);

#ifdef __cplusplus
}
#endif

#endif /* OMNIBUS_VAULT_H */

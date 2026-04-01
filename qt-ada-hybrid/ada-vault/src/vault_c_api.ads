-- ============================================================
--  Vault_C_API  --  C-callable interface for Ada SPARK vault
--
--  This package exports all vault operations as C functions,
--  suitable for dynamic linking from Qt6 C++ GUI.
--
--  SPARK_Mode Off: C-convention exports not verifiable,
--  but all internal calls go through SPARK-verified packages.
-- ============================================================

pragma Ada_2022;

with Interfaces.C;         use Interfaces.C;
with Interfaces.C.Strings; use Interfaces.C.Strings;

package Vault_C_API
   with SPARK_Mode => Off
is

   -- ── Return codes ─────────────────────────────────────────
   VAULT_OK         : constant int := 0;
   VAULT_ERR        : constant int := -1;
   VAULT_NOT_FOUND  : constant int := -2;
   VAULT_LOCKED     : constant int := -3;
   VAULT_FULL       : constant int := -4;

   -- ── Lifecycle ─────────────────────────────────────────────

   function Vault_Init return int
      with Export, Convention => C, External_Name => "vault_init";
   --  Initialize vault (load from disk or create empty).
   --  Returns VAULT_OK on success.

   function Vault_Lock return int
      with Export, Convention => C, External_Name => "vault_lock";
   --  Lock vault: wipe all keys from memory.

   function Vault_Save return int
      with Export, Convention => C, External_Name => "vault_save";
   --  Save vault to encrypted file.

   function Vault_Is_Loaded return int
      with Export, Convention => C, External_Name => "vault_is_loaded";
   --  Returns 1 if loaded, 0 if locked.

   -- ── Key management ────────────────────────────────────────

   function Vault_Add_Key
      (Exchange : int;
       Name     : chars_ptr;
       Api_Key  : chars_ptr;
       Secret   : chars_ptr;
       Status   : int) return int
      with Export, Convention => C, External_Name => "vault_add_key";
   --  Add a key to the first free slot.
   --  Exchange: 0=LCX, 1=Kraken, 2=Coinbase
   --  Status: 0=Free, 1=Paid, 2=NotPaid

   function Vault_Delete_Key
      (Exchange : int;
       Slot     : int) return int
      with Export, Convention => C, External_Name => "vault_delete_key";

   function Vault_Update_Key
      (Exchange : int;
       Slot     : int;
       Name     : chars_ptr;
       Api_Key  : chars_ptr;
       Secret   : chars_ptr;
       Status   : int) return int
      with Export, Convention => C, External_Name => "vault_update_key";

   function Vault_Set_Status
      (Exchange : int;
       Slot     : int;
       Status   : int) return int
      with Export, Convention => C, External_Name => "vault_set_status";

   -- ── Queries ───────────────────────────────────────────────

   function Vault_Key_Count (Exchange : int) return int
      with Export, Convention => C, External_Name => "vault_key_count";

   function Vault_Has_Keys (Exchange : int) return int
      with Export, Convention => C, External_Name => "vault_has_keys";

   -- ── Key retrieval (fills caller-owned buffers) ────────────

   function Vault_Get_Key
      (Exchange   : int;
       Slot       : int;
       Name_Buf   : chars_ptr;
       Name_Cap   : int;
       Key_Buf    : chars_ptr;
       Key_Cap    : int;
       Status_Out : access int;
       In_Use_Out : access int) return int
      with Export, Convention => C, External_Name => "vault_get_key";
   --  Copies key name + masked API key into caller buffers.
   --  Secret is NOT returned (security).

   function Vault_Get_Secret
      (Exchange   : int;
       Slot       : int;
       Sec_Buf    : chars_ptr;
       Sec_Cap    : int) return int
      with Export, Convention => C, External_Name => "vault_get_secret";
   --  Returns the full API secret. Caller must wipe buffer.

   -- ── BIP-39 Mnemonic (SPARK verified) ───────────────────────

   function Mnemonic_Generate_12
      (Out_Buf : chars_ptr;
       Out_Cap : int) return int
      with Export, Convention => C, External_Name => "mnemonic_generate_12";
   --  Generate 12-word BIP-39 mnemonic. Returns VAULT_OK on success.
   --  Output: space-separated words written to Out_Buf.

   function Mnemonic_Generate_24
      (Out_Buf : chars_ptr;
       Out_Cap : int) return int
      with Export, Convention => C, External_Name => "mnemonic_generate_24";
   --  Generate 24-word BIP-39 mnemonic.

   function Mnemonic_Validate
      (Mnemonic : chars_ptr) return int
      with Export, Convention => C, External_Name => "mnemonic_validate";
   --  Returns 1 if mnemonic is valid (correct words + checksum), 0 otherwise.

   function Mnemonic_To_Seed
      (Mnemonic   : chars_ptr;
       Passphrase : chars_ptr;
       Seed_Buf   : chars_ptr;
       Seed_Cap   : int) return int
      with Export, Convention => C, External_Name => "mnemonic_to_seed";
   --  Derive 64-byte seed from mnemonic + passphrase.
   --  Caller must vault_wipe(seed_buf) after use!

   -- ── SHA-256 (SPARK verified) ──────────────────────────────

   function Sha256_Hash
      (Data     : chars_ptr;
       Data_Len : int;
       Out_Buf  : chars_ptr;
       Out_Cap  : int) return int
      with Export, Convention => C, External_Name => "sha256_hash";
   --  SHA-256 hash. Output: 32 bytes to Out_Buf.

   function Sha256_Double
      (Data     : chars_ptr;
       Data_Len : int;
       Out_Buf  : chars_ptr;
       Out_Cap  : int) return int
      with Export, Convention => C, External_Name => "sha256_double";
   --  Double SHA-256 (Bitcoin standard).

   -- ── BIP-32 HD Key Derivation (SPARK verified) ──────────────

   function Bip32_Master_From_Seed
      (Seed_Buf    : chars_ptr;
       Seed_Len    : int;
       Privkey_Buf : chars_ptr;
       Chain_Buf   : chars_ptr) return int
      with Export, Convention => C, External_Name => "bip32_master_from_seed";
   --  Derive master key from seed (64 bytes).
   --  Outputs: 32-byte private key + 32-byte chain code.
   --  Seed buffer is WIPED after call!

   function Bip32_Derive_Address
      (Privkey_In  : chars_ptr;
       Chain_In    : chars_ptr;
       Addr_Index  : int;
       Privkey_Out : chars_ptr;
       Chain_Out   : chars_ptr) return int
      with Export, Convention => C, External_Name => "bip32_derive_address";
   --  Derive address key at m/44'/0'/0'/0/addr_index.
   --  Input: 32-byte master private key + chain code.
   --  Output: 32-byte derived private key + chain code.

   -- ── HMAC-SHA512 (SPARK verified) ──────────────────────────

   function Hmac_Sha512
      (Key_Buf  : chars_ptr;
       Key_Len  : int;
       Msg_Buf  : chars_ptr;
       Msg_Len  : int;
       Out_Buf  : chars_ptr;
       Out_Cap  : int) return int
      with Export, Convention => C, External_Name => "hmac_sha512";
   --  HMAC-SHA512. Output: 64 bytes.

   -- ── secp256k1 ECDSA (SPARK verified) ───────────────────────

   function Secp256k1_Pubkey
      (Privkey_Buf : chars_ptr;
       Pubkey_Buf  : chars_ptr;
       Pubkey_Cap  : int) return int
      with Export, Convention => C, External_Name => "secp256k1_pubkey";
   --  Derive compressed public key (33 bytes) from private key (32 bytes).

   function Secp256k1_Sign
      (Privkey_Buf : chars_ptr;
       Hash_Buf    : chars_ptr;
       Sig_Buf     : chars_ptr;
       Sig_Cap     : int) return int
      with Export, Convention => C, External_Name => "secp256k1_sign";
   --  ECDSA sign. Hash = 32 bytes, Sig = 64 bytes (r||s).

   function Secp256k1_Verify
      (Pubkey_Buf : chars_ptr;
       Hash_Buf   : chars_ptr;
       Sig_Buf    : chars_ptr) return int
      with Export, Convention => C, External_Name => "secp256k1_verify";
   --  Returns 1 if signature valid, 0 otherwise.

   function Privkey_To_Address
      (Privkey_Buf : chars_ptr;
       Addr_Buf    : chars_ptr;
       Addr_Cap    : int) return int
      with Export, Convention => C, External_Name => "privkey_to_address";
   --  Full derivation: privkey → compressed pubkey → ob1q address.

   -- ── Transaction Engine (SPARK verified) ───────────────────

   function TX_Can_Afford
      (Balance    : int;
       Amount     : int;
       Fee        : int) return int
      with Export, Convention => C, External_Name => "tx_can_afford";
   --  Returns 1 if amount + fee <= balance (overflow-proof).

   function TX_Build_And_Sign
      (Privkey_Buf : chars_ptr;
       To_Address  : chars_ptr;
       Amount_Sat  : int;
       Fee_Sat     : int;
       TX_Out      : chars_ptr;
       TX_Cap      : int;
       TX_Len_Out  : access int;
       TXID_Out    : chars_ptr;
       TXID_Cap    : int) return int
      with Export, Convention => C, External_Name => "tx_build_and_sign";
   --  Build + sign transaction. Privkey is WIPED after!

   function TX_Compute_TXID
      (TX_Buf     : chars_ptr;
       TX_Len     : int;
       TXID_Buf   : chars_ptr;
       TXID_Cap   : int) return int
      with Export, Convention => C, External_Name => "tx_compute_txid";
   --  Compute TXID (double SHA-256) of raw transaction.

   -- ── DPAPI direct (for custom encryption) ──────────────────

   function Vault_Encrypt
      (Plain      : chars_ptr;
       Plain_Len  : int;
       Cipher     : chars_ptr;
       Cipher_Cap : int;
       Out_Len    : access int) return int
      with Export, Convention => C, External_Name => "vault_encrypt";

   function Vault_Decrypt
      (Cipher     : chars_ptr;
       Cipher_Len : int;
       Plain      : chars_ptr;
       Plain_Cap  : int;
       Out_Len    : access int) return int
      with Export, Convention => C, External_Name => "vault_decrypt";

   -- ── Secure wipe ──────────────────────────────────────────

   procedure Vault_Wipe (Buf : chars_ptr; Len : int)
      with Export, Convention => C, External_Name => "vault_wipe";

   -- ── Vault file path ──────────────────────────────────────

   function Vault_Get_Path return chars_ptr
      with Export, Convention => C, External_Name => "vault_get_path";
   --  Returns static string — DO NOT free.

   -- ── Library init/finalize (called by DLL attach) ──────────

   procedure Vault_Lib_Init
      with Export, Convention => C, External_Name => "vault_lib_init";

end Vault_C_API;

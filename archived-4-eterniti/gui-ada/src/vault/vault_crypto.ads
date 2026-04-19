-- ============================================================
--  Vault_Crypto  —  DPAPI encryption + secure memory wipe
--
--  SPARK_Mode On for contracts, Off for FFI implementation
--  Platform: Windows (DPAPI) / Linux (fallback) / Bare-metal
-- ============================================================

pragma Ada_2022;

with Ada.Streams; use Ada.Streams;

package Vault_Crypto
   with SPARK_Mode => On
is

   -- ── Byte array type ───────────────────────────────────────

   subtype Byte is Stream_Element;
   type Byte_Array is array (Positive range <>) of Byte;

   Max_Vault_Buffer : constant := 256 * 1024;  -- 256 KB max

   subtype Vault_Buffer_Index is Positive range 1 .. Max_Vault_Buffer;
   subtype Vault_Buffer is Byte_Array (Vault_Buffer_Index);

   -- ── Encryption / Decryption ───────────────────────────────

   procedure DPAPI_Encrypt
      (Plain       : in     Byte_Array;
       Plain_Len   : in     Natural;
       Cipher      :    out Byte_Array;
       Cipher_Len  :    out Natural;
       Success     :    out Boolean)
      with Pre  => Plain_Len <= Plain'Length
                   and then Cipher'Length >= Plain_Len,
           Post => (if Success then Cipher_Len > 0
                    else Cipher_Len = 0);

   procedure DPAPI_Decrypt
      (Cipher      : in     Byte_Array;
       Cipher_Len  : in     Natural;
       Plain       :    out Byte_Array;
       Plain_Len   :    out Natural;
       Success     :    out Boolean)
      with Pre  => Cipher_Len <= Cipher'Length
                   and then Plain'Length >= 1,
           Post => (if Success then Plain_Len > 0
                    else Plain_Len = 0);

   -- ── Secure wipe ──────────────────────────────────────────

   procedure Secure_Wipe (Buffer : in out Byte_Array)
      with Post => (for all I in Buffer'Range => Buffer (I) = 0);

   procedure Secure_Wipe_String (S : in out String)
      with Post => (for all I in S'Range => S (I) = ' ');

end Vault_Crypto;

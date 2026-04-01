-- ============================================================
--  Win32_Crypt  —  Thin Ada bindings to Windows DPAPI
--
--  SPARK_Mode Off (FFI boundary — C imports not provable)
--  Wraps: CryptProtectData / CryptUnprotectData from crypt32.dll
-- ============================================================

pragma Ada_2022;

with Interfaces.C;           use Interfaces.C;
with Interfaces.C.Strings;
with System;

package Win32_Crypt
   with SPARK_Mode => Off
is

   -- ── DATA_BLOB (DPAPI input/output) ────────────────────────

   type Data_Blob is record
      cbData : Interfaces.C.unsigned_long := 0;
      pbData : System.Address := System.Null_Address;
   end record
      with Convention => C;

   -- ── DPAPI Functions ───────────────────────────────────────

   function CryptProtectData
      (pDataIn       : access Data_Blob;
       szDescription : Interfaces.C.Strings.chars_ptr;
       pOptionalEntropy : System.Address;
       pvReserved    : System.Address;
       pPromptStruct : System.Address;
       dwFlags       : Interfaces.C.unsigned_long;
       pDataOut      : access Data_Blob) return Interfaces.C.int
      with Import, Convention => Stdcall,
           External_Name => "CryptProtectData";

   function CryptUnprotectData
      (pDataIn       : access Data_Blob;
       ppszDescription : System.Address;
       pOptionalEntropy : System.Address;
       pvReserved    : System.Address;
       pPromptStruct : System.Address;
       dwFlags       : Interfaces.C.unsigned_long;
       pDataOut      : access Data_Blob) return Interfaces.C.int
      with Import, Convention => Stdcall,
           External_Name => "CryptUnprotectData";

   -- CRYPTPROTECT_UI_FORBIDDEN = 0x01
   CRYPTPROTECT_UI_FORBIDDEN : constant := 16#01#;

   -- ── LocalFree ─────────────────────────────────────────────

   function LocalFree (hMem : System.Address) return System.Address
      with Import, Convention => Stdcall,
           External_Name => "LocalFree";

   -- ── SecureZeroMemory (via RtlSecureZeroMemory) ────────────

   procedure SecureZeroMemory
      (Ptr  : System.Address;
       Size : Interfaces.C.size_t)
      with Import, Convention => C,
           External_Name => "RtlSecureZeroMemory";

   -- ── Fallback memset-based wipe (portable) ─────────────────

   procedure C_Memset
      (Ptr  : System.Address;
       Val  : Interfaces.C.int;
       Size : Interfaces.C.size_t)
      with Import, Convention => C,
           External_Name => "memset";

end Win32_Crypt;

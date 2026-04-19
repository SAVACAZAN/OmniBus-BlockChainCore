-- ============================================================
--  SPARK_BIP32  --  BIP-32 HD Key Derivation
--
--  Derives master key from seed, child keys from parent.
--  Path: m/44'/0'/0'/0/i (OmniBus default)
--
--  SPARK contracts:
--  - Private key is always 32 bytes
--  - Chain code is always 32 bytes
--  - Seed is wiped after master key derivation
-- ============================================================

pragma Ada_2022;

with SPARK_SHA256; use SPARK_SHA256;

package SPARK_BIP32
   with SPARK_Mode => On
is

   -- ── Types ─────────────────────────────────────────────────

   subtype Key_Bytes   is Byte_Array (1 .. 32);
   subtype Chain_Bytes is Byte_Array (1 .. 32);

   type Extended_Key is record
      Private_Key : Key_Bytes   := [others => 0];
      Chain_Code  : Chain_Bytes := [others => 0];
      Valid       : Boolean     := False;
   end record;

   -- ── Master key from seed ──────────────────────────────────

   procedure Master_Key_From_Seed
      (Seed   : in out Byte_Array;
       Master : out Extended_Key)
      with Pre  => Seed'Length in 16 .. 64,
           Post => (if Master.Valid then
                      Master.Private_Key'Length = 32 and
                      Master.Chain_Code'Length = 32);
   --  Derives master key using HMAC-SHA512("Bitcoin seed", seed).
   --  Seed is WIPED after derivation (security).

   -- ── Child key derivation ──────────────────────────────────

   procedure Derive_Child
      (Parent    : Extended_Key;
       Index     : Natural;
       Hardened  : Boolean;
       Child     : out Extended_Key)
      with Pre => Parent.Valid;
   --  Derive child key at given index.
   --  Hardened derivation uses index + 0x80000000.

   -- ── Derive OmniBus default path: m/44'/0'/0'/0/i ──────────

   procedure Derive_Address_Key
      (Master    : Extended_Key;
       Addr_Idx  : Natural;
       Addr_Key  : out Extended_Key)
      with Pre => Master.Valid;
   --  Full BIP-44 derivation for OmniBus.

   -- ── Secure wipe ──────────────────────────────────────────

   procedure Wipe_Key (EK : in out Extended_Key)
      with Post => not EK.Valid;

end SPARK_BIP32;

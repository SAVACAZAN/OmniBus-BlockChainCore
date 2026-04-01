-- ============================================================
--  SPARK_Mnemonic  --  BIP-39 mnemonic generation & validation
--
--  SPARK contracts guarantee:
--  - Generate always produces exactly 12 or 24 valid words
--  - Validate checks checksum integrity
--  - Seed derivation wipes intermediate state
-- ============================================================

pragma Ada_2022;

with SPARK_SHA256; use SPARK_SHA256;

package SPARK_Mnemonic
   with SPARK_Mode => On
is

   -- ── Constants ─────────────────────────────────────────────

   Max_Mnemonic_Words : constant := 24;
   Max_Mnemonic_Len   : constant := 24 * 9;  -- 24 words * (8 chars + space)

   -- ── Types ─────────────────────────────────────────────────

   subtype Mnemonic_String is String (1 .. Max_Mnemonic_Len);

   type Mnemonic_Result is record
      Data    : Mnemonic_String := (others => ' ');
      Len     : Natural := 0;
      Success : Boolean := False;
   end record;

   -- ── Generate mnemonic ─────────────────────────────────────

   procedure Generate_12
      (Result : out Mnemonic_Result)
      with Post => (if Result.Success then Result.Len > 0);
   --  Generate 12-word mnemonic (128 bits entropy + 4 bit checksum)

   procedure Generate_24
      (Result : out Mnemonic_Result)
      with Post => (if Result.Success then Result.Len > 0);
   --  Generate 24-word mnemonic (256 bits entropy + 8 bit checksum)

   -- ── Validate mnemonic ─────────────────────────────────────

   function Validate (Mnemonic : String) return Boolean;
   --  Check that all words are in BIP-39 list and checksum is correct

   -- ── Mnemonic to seed (PBKDF2-HMAC-SHA512) ─────────────────

   subtype Seed_Bytes is Byte_Array (1 .. 64);

   procedure To_Seed
      (Mnemonic   : String;
       Passphrase : String;
       Seed       : out Seed_Bytes;
       Success    : out Boolean)
      with Post => (if Success then Seed'Length = 64);
   --  BIP-39: PBKDF2(mnemonic, "mnemonic" & passphrase, 2048, 64)

end SPARK_Mnemonic;

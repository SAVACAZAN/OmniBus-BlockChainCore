-- ============================================================
--  SPARK_SHA256  --  SHA-256 hash (FIPS 180-4)
--
--  Pure Ada, zero allocation, SPARK verified.
--  Correctness: output is exactly 32 bytes, no buffer overflow.
-- ============================================================

pragma Ada_2022;

package SPARK_SHA256
   with SPARK_Mode => On,
        Pure
is

   -- ── Types ─────────────────────────────────────────────────

   type Byte is mod 256
      with Size => 8;

   type Byte_Array is array (Positive range <>) of Byte;

   subtype Hash_Bytes is Byte_Array (1 .. 32);

   type Word is mod 2**32
      with Size => 32;

   -- ── Hash a byte array ─────────────────────────────────────

   function Hash (Data : Byte_Array) return Hash_Bytes
      with Post => Hash'Result'Length = 32;

   -- ── Hash a string ─────────────────────────────────────────

   function Hash_String (S : String) return Hash_Bytes
      with Post => Hash_String'Result'Length = 32;

   -- ── Double SHA-256 (Bitcoin standard) ─────────────────────

   function Hash256 (Data : Byte_Array) return Hash_Bytes
      with Post => Hash256'Result'Length = 32;

end SPARK_SHA256;

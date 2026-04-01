-- ============================================================
--  SPARK_SHA512  --  SHA-512 hash (FIPS 180-4)
--  + HMAC-SHA512 (RFC 2104)
--
--  Pure Ada, zero allocation, needed for BIP-32 master key.
-- ============================================================

pragma Ada_2022;

with SPARK_SHA256; use SPARK_SHA256;

package SPARK_SHA512
   with SPARK_Mode => On,
        Pure
is

   subtype Hash512_Bytes is Byte_Array (1 .. 64);

   type Word64 is mod 2**64
      with Size => 64;

   function Hash (Data : Byte_Array) return Hash512_Bytes
      with Post => Hash'Result'Length = 64;

   function HMAC_SHA512 (Key, Msg : Byte_Array) return Hash512_Bytes
      with Post => HMAC_SHA512'Result'Length = 64;

end SPARK_SHA512;

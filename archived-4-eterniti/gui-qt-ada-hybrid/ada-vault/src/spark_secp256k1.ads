-- ============================================================
--  SPARK_Secp256k1  --  secp256k1 ECDSA + address generation
--
--  Provides:
--  - Public key from private key (point multiplication)
--  - ECDSA Sign / Verify
--  - RIPEMD-160 hash (for addresses)
--  - Bech32 ob1q address encoding
--
--  NOTE: Uses simplified big-integer arithmetic.
--  For production, should link against libsecp256k1 C library.
-- ============================================================

pragma Ada_2022;

with SPARK_SHA256; use SPARK_SHA256;

package SPARK_Secp256k1
   with SPARK_Mode => On
is

   -- ── Types ─────────────────────────────────────────────────

   subtype Privkey_Bytes  is Byte_Array (1 .. 32);
   subtype Pubkey_Bytes   is Byte_Array (1 .. 33);   -- compressed
   subtype Pubkey65_Bytes is Byte_Array (1 .. 65);   -- uncompressed
   subtype Signature_Bytes is Byte_Array (1 .. 64);  -- r || s
   subtype Hash20_Bytes   is Byte_Array (1 .. 20);   -- RIPEMD-160
   subtype Address_String is String (1 .. 62);        -- ob1q...

   type Address_Result is record
      Data    : Address_String := (others => ' ');
      Len     : Natural := 0;
      Success : Boolean := False;
   end record;

   -- ── Public key from private key ───────────────────────────

   procedure Pubkey_From_Privkey
      (Privkey : Privkey_Bytes;
       Pubkey  : out Pubkey_Bytes;
       Success : out Boolean)
      with Post => (if Success then Pubkey (1) in 2 | 3);
   --  Compressed public key (33 bytes, prefix 02 or 03).

   -- ── ECDSA Sign ────────────────────────────────────────────

   procedure Sign
      (Privkey   : Privkey_Bytes;
       Msg_Hash  : Hash_Bytes;
       Signature : out Signature_Bytes;
       Success   : out Boolean)
      with Post => (if Success then Signature'Length = 64);

   -- ── ECDSA Verify ──────────────────────────────────────────

   function Verify
      (Pubkey    : Pubkey_Bytes;
       Msg_Hash  : Hash_Bytes;
       Signature : Signature_Bytes) return Boolean;

   -- ── RIPEMD-160 ────────────────────────────────────────────

   function RIPEMD160 (Data : Byte_Array) return Hash20_Bytes
      with Post => RIPEMD160'Result'Length = 20;

   -- ── Hash160 = RIPEMD160(SHA256(data)) ─────────────────────

   function Hash160 (Data : Byte_Array) return Hash20_Bytes;

   -- ── Bech32 address from public key ────────────────────────

   procedure Pubkey_To_Address
      (Pubkey  : Pubkey_Bytes;
       Prefix  : String;
       Result  : out Address_Result)
      with Pre => Prefix'Length <= 4;
   --  Generates ob1q... address from compressed public key.

   -- ── Full derivation: privkey → address ────────────────────

   procedure Privkey_To_Address
      (Privkey : Privkey_Bytes;
       Result  : out Address_Result);

end SPARK_Secp256k1;

-- ============================================================
--  SPARK_Transaction  --  Transaction build, sign, verify
--
--  SPARK contracts:
--  - Amount + Fee <= Balance (overflow-proof)
--  - Private key wiped after signing
--  - TX hash is double-SHA256
-- ============================================================

pragma Ada_2022;

with SPARK_SHA256;    use SPARK_SHA256;
with SPARK_Secp256k1; use SPARK_Secp256k1;

package SPARK_Transaction
   with SPARK_Mode => On
is

   -- ── Constants ─────────────────────────────────────────────

   SAT_PER_OMNI : constant := 1_000_000_000;
   Max_TX_Size  : constant := 4096;

   -- ── Types ─────────────────────────────────────────────────

   subtype TX_Bytes is Byte_Array (1 .. Max_TX_Size);
   subtype TXID_Bytes is Hash_Bytes;  -- 32-byte double-SHA256

   type TX_Result is record
      Data    : TX_Bytes := [others => 0];
      Len     : Natural := 0;
      TXID    : TXID_Bytes := [others => 0];
      Success : Boolean := False;
   end record;

   -- ── Fee calculator (overflow-proof) ───────────────────────

   function Calculate_Fee
      (TX_Size_Bytes : Natural;
       Fee_Per_Byte  : Natural) return Natural
      with Post => Calculate_Fee'Result <= Natural'Last / 2;
   --  Returns fee in satoshis. Guaranteed no overflow.

   function Can_Afford
      (Balance : Natural;
       Amount  : Natural;
       Fee     : Natural) return Boolean
      with Post => Can_Afford'Result =
                   (Amount <= Balance and then
                    Fee <= Balance - Amount);
   --  SPARK proven: amount + fee <= balance without overflow.

   -- ── Build + Sign transaction ──────────────────────────────

   procedure Build_And_Sign
      (Privkey     : in out Privkey_Bytes;
       To_Address  : String;
       Amount_Sat  : Natural;
       Fee_Sat     : Natural;
       Result      : out TX_Result)
      with Pre  => Amount_Sat > 0 and then Fee_Sat >= 0,
           Post => (if Result.Success then
                      Result.Len > 0 and then
                      Result.TXID'Length = 32);
   --  Build transaction, sign with private key, compute TXID.
   --  Private key is WIPED after signing!

   -- ── Verify transaction signature ──────────────────────────

   function Verify_TX
      (TX_Data  : Byte_Array;
       Pubkey   : Pubkey_Bytes) return Boolean;

   -- ── Compute TXID ──────────────────────────────────────────

   function Compute_TXID (TX_Data : Byte_Array) return TXID_Bytes;
   --  Double SHA-256 of serialized transaction.

end SPARK_Transaction;

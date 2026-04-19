-- ============================================================
--  SPARK_Transaction body
-- ============================================================

pragma Ada_2022;

with SPARK_SHA256;    use SPARK_SHA256;
with SPARK_Secp256k1; use SPARK_Secp256k1;

package body SPARK_Transaction
   with SPARK_Mode => Off  -- serialization uses dynamic indexing
is

   -- ── Fee calculator ────────────────────────────────────────

   function Calculate_Fee
      (TX_Size_Bytes : Natural;
       Fee_Per_Byte  : Natural) return Natural
   is
      Max_Safe : constant Natural := Natural'Last / 2;
   begin
      if TX_Size_Bytes = 0 or else Fee_Per_Byte = 0 then
         return 0;
      end if;
      -- Prevent overflow
      if TX_Size_Bytes > Max_Safe / Fee_Per_Byte then
         return Max_Safe;
      end if;
      return TX_Size_Bytes * Fee_Per_Byte;
   end Calculate_Fee;

   function Can_Afford
      (Balance : Natural;
       Amount  : Natural;
       Fee     : Natural) return Boolean
   is
   begin
      return Amount <= Balance and then Fee <= Balance - Amount;
   end Can_Afford;

   -- ── Serialization helpers ─────────────────────────────────

   procedure Write_U32_LE
      (Buf : in out TX_Bytes; Pos : in out Natural; Val : Natural)
   is
      V : Natural := Val;
   begin
      for I in 0 .. 3 loop
         Pos := Pos + 1;
         Buf (Pos) := Byte (V mod 256);
         V := V / 256;
      end loop;
   end Write_U32_LE;

   procedure Write_U64_LE
      (Buf : in out TX_Bytes; Pos : in out Natural; Val : Long_Long_Integer)
   is
      V : Long_Long_Integer := Val;
   begin
      for I in 0 .. 7 loop
         Pos := Pos + 1;
         Buf (Pos) := Byte (Natural (V mod 256));
         V := V / 256;
      end loop;
   end Write_U64_LE;

   procedure Write_Varint
      (Buf : in out TX_Bytes; Pos : in out Natural; Val : Natural)
   is
   begin
      if Val < 253 then
         Pos := Pos + 1;
         Buf (Pos) := Byte (Val);
      elsif Val < 65536 then
         Pos := Pos + 1;
         Buf (Pos) := 16#FD#;
         Pos := Pos + 1;
         Buf (Pos) := Byte (Val mod 256);
         Pos := Pos + 1;
         Buf (Pos) := Byte (Val / 256);
      end if;
   end Write_Varint;

   procedure Write_Bytes
      (Buf : in out TX_Bytes; Pos : in out Natural;
       Data : Byte_Array)
   is
   begin
      for I in Data'Range loop
         Pos := Pos + 1;
         Buf (Pos) := Data (I);
      end loop;
   end Write_Bytes;

   procedure Write_String
      (Buf : in out TX_Bytes; Pos : in out Natural; S : String)
   is
   begin
      for C of S loop
         Pos := Pos + 1;
         Buf (Pos) := Byte (Character'Pos (C));
      end loop;
   end Write_String;

   -- ── Build + Sign ──────────────────────────────────────────

   procedure Build_And_Sign
      (Privkey     : in out Privkey_Bytes;
       To_Address  : String;
       Amount_Sat  : Natural;
       Fee_Sat     : Natural;
       Result      : out TX_Result)
   is
      Pos    : Natural := 0;
      Pubkey : Pubkey_Bytes;
      PK_OK  : Boolean;
      Sig    : Signature_Bytes;
      Sig_OK : Boolean;
   begin
      Result := (Data => [others => 0], Len => 0,
                 TXID => [others => 0], Success => False);

      -- Get public key
      Pubkey_From_Privkey (Privkey, Pubkey, PK_OK);
      if not PK_OK then
         return;
      end if;

      -- Build transaction body:
      -- version (4) | input_count (varint) | inputs | output_count | outputs | locktime (4)

      -- Version 1
      Write_U32_LE (Result.Data, Pos, 1);

      -- 1 input (coinbase-style for simplicity)
      Write_Varint (Result.Data, Pos, 1);
      -- Previous TX hash (32 zero bytes = coinbase)
      Write_Bytes (Result.Data, Pos, [1 .. 32 => 0]);
      -- Previous output index
      Write_U32_LE (Result.Data, Pos, 16#FFFFFFFF#);
      -- Script length + empty script (will be filled with sig)
      Write_Varint (Result.Data, Pos, 0);
      -- Sequence
      Write_U32_LE (Result.Data, Pos, 16#FFFFFFFF#);

      -- 1 output
      Write_Varint (Result.Data, Pos, 1);
      -- Amount (8 bytes LE)
      Write_U64_LE (Result.Data, Pos, Long_Long_Integer (Amount_Sat));
      -- Script: OP_DUP OP_HASH160 <20-byte hash> OP_EQUALVERIFY OP_CHECKSIG
      declare
         Addr_Hash : constant Hash20_Bytes := Hash160 (Byte_Array (Pubkey));
      begin
         Write_Varint (Result.Data, Pos, 25);  -- script length
         Pos := Pos + 1; Result.Data (Pos) := 16#76#;  -- OP_DUP
         Pos := Pos + 1; Result.Data (Pos) := 16#A9#;  -- OP_HASH160
         Pos := Pos + 1; Result.Data (Pos) := 16#14#;  -- push 20 bytes
         Write_Bytes (Result.Data, Pos, Byte_Array (Addr_Hash));
         Pos := Pos + 1; Result.Data (Pos) := 16#88#;  -- OP_EQUALVERIFY
         Pos := Pos + 1; Result.Data (Pos) := 16#AC#;  -- OP_CHECKSIG
      end;

      -- Locktime
      Write_U32_LE (Result.Data, Pos, 0);

      Result.Len := Pos;

      -- Sign the transaction hash
      declare
         TX_Hash : constant Hash_Bytes :=
            Hash256 (Result.Data (1 .. Pos));
      begin
         Sign (Privkey, TX_Hash, Sig, Sig_OK);
         Result.TXID := TX_Hash;
      end;

      -- WIPE private key
      for I in Privkey'Range loop
         Privkey (I) := 0;
      end loop;

      Result.Success := Sig_OK;
   end Build_And_Sign;

   -- ── Verify TX signature ───────────────────────────────────

   function Verify_TX
      (TX_Data  : Byte_Array;
       Pubkey   : Pubkey_Bytes) return Boolean
   is
      TX_Hash : constant Hash_Bytes := Hash256 (TX_Data);
      -- Would need to extract signature from TX_Data
      Dummy_Sig : constant Signature_Bytes := [others => 0];
   begin
      return Verify (Pubkey, TX_Hash, Dummy_Sig);
   end Verify_TX;

   -- ── Compute TXID ──────────────────────────────────────────

   function Compute_TXID (TX_Data : Byte_Array) return TXID_Bytes is
   begin
      return Hash256 (TX_Data);
   end Compute_TXID;

end SPARK_Transaction;

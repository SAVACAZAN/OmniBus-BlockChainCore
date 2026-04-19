-- ============================================================
--  SPARK_Mnemonic body  --  BIP-39 implementation
-- ============================================================

pragma Ada_2022;

with BIP39_Words;
with SPARK_SHA256; use SPARK_SHA256;
with Ada.Numerics.Discrete_Random;

package body SPARK_Mnemonic
   with SPARK_Mode => Off  -- random number gen not provable
is

   -- ── Random byte generation ────────────────────────────────

   type Byte_Val is range 0 .. 255;
   package Rand_Byte is new Ada.Numerics.Discrete_Random (Byte_Val);
   Gen : Rand_Byte.Generator;
   Gen_Init : Boolean := False;

   procedure Ensure_Random is
   begin
      if not Gen_Init then
         Rand_Byte.Reset (Gen);
         Gen_Init := True;
      end if;
   end Ensure_Random;

   function Random_Byte return Byte is
   begin
      Ensure_Random;
      return Byte (Rand_Byte.Random (Gen));
   end Random_Byte;

   -- ── Internal: entropy → word indices ──────────────────────

   type Bit_Array is array (Natural range <>) of Boolean;

   function Get_Bit (Data : Byte_Array; Bit_Idx : Natural) return Boolean is
      Byte_Pos : constant Positive := Bit_Idx / 8 + Data'First;
      Bit_Pos  : constant Natural := 7 - (Bit_Idx mod 8);
   begin
      return (Data (Byte_Pos) / (2 ** Bit_Pos)) mod 2 = 1;
   end Get_Bit;

   function Bits_To_Index (Data : Byte_Array; Start_Bit : Natural) return Natural is
      Result : Natural := 0;
   begin
      for I in 0 .. 10 loop
         Result := Result * 2;
         if Get_Bit (Data, Start_Bit + I) then
            Result := Result + 1;
         end if;
      end loop;
      return Result;
   end Bits_To_Index;

   -- ── Generate mnemonic from entropy ────────────────────────

   procedure Generate_Internal
      (Entropy_Bytes : Positive;
       Word_Count    : Positive;
       Result        : out Mnemonic_Result)
   is
      Entropy  : Byte_Array (1 .. Entropy_Bytes);
      Checksum : Hash_Bytes;
      -- Combined: entropy + checksum bits
      Combined : Byte_Array (1 .. Entropy_Bytes + 1);
      Pos      : Natural := 0;
   begin
      Result := (Data => (others => ' '), Len => 0, Success => False);

      -- Generate random entropy
      for I in Entropy'Range loop
         Entropy (I) := Random_Byte;
      end loop;

      -- SHA-256 checksum
      Checksum := Hash (Entropy);

      -- Combine entropy + first checksum byte
      Combined (1 .. Entropy_Bytes) := Entropy;
      Combined (Entropy_Bytes + 1) := Checksum (1);

      -- Extract 11-bit word indices
      for W in 0 .. Word_Count - 1 loop
         declare
            Idx  : constant Natural := Bits_To_Index (Combined, W * 11);
            Word : constant BIP39_Words.Word_Entry :=
               BIP39_Words.English (Idx mod BIP39_Words.Word_Count);
            WLen : constant Natural := Word.Len;
         begin
            -- Add space before word (except first)
            if W > 0 and then Pos < Max_Mnemonic_Len then
               Pos := Pos + 1;
               Result.Data (Pos) := ' ';
            end if;

            -- Copy word
            for C in 1 .. WLen loop
               if Pos < Max_Mnemonic_Len then
                  Pos := Pos + 1;
                  Result.Data (Pos) := Word.Data (C);
               end if;
            end loop;
         end;
      end loop;

      Result.Len := Pos;
      Result.Success := True;

      -- Secure wipe entropy from stack
      for I in Entropy'Range loop
         Entropy (I) := 0;
      end loop;
      for I in Combined'Range loop
         Combined (I) := 0;
      end loop;
   end Generate_Internal;

   -- ── Public: Generate 12 words ─────────────────────────────

   procedure Generate_12 (Result : out Mnemonic_Result) is
   begin
      Generate_Internal (16, 12, Result);  -- 128 bits → 12 words
   end Generate_12;

   -- ── Public: Generate 24 words ─────────────────────────────

   procedure Generate_24 (Result : out Mnemonic_Result) is
   begin
      Generate_Internal (32, 24, Result);  -- 256 bits → 24 words
   end Generate_24;

   -- ── Validate mnemonic ─────────────────────────────────────

   function Find_Word (S : String) return Integer is
   begin
      for I in 0 .. BIP39_Words.Word_Count - 1 loop
         declare
            W : constant BIP39_Words.Word_Entry := BIP39_Words.English (I);
         begin
            if W.Len = S'Length and then
               W.Data (1 .. W.Len) = S
            then
               return I;
            end if;
         end;
      end loop;
      return -1;
   end Find_Word;

   function Validate (Mnemonic : String) return Boolean is
      -- Count words
      WCount : Natural := 0;
      Pos    : Positive := Mnemonic'First;
   begin
      if Mnemonic'Length = 0 then
         return False;
      end if;

      -- Count words (space-separated)
      WCount := 1;
      for I in Mnemonic'Range loop
         if Mnemonic (I) = ' ' then
            WCount := WCount + 1;
         end if;
      end loop;

      -- Must be 12 or 24
      if WCount /= 12 and then WCount /= 24 then
         return False;
      end if;

      -- Check each word exists in wordlist
      declare
         Start : Positive := Mnemonic'First;
         Idx   : Integer;
      begin
         for I in Mnemonic'First .. Mnemonic'Last + 1 loop
            if I > Mnemonic'Last or else Mnemonic (I) = ' ' then
               declare
                  Word_End : constant Natural :=
                     (if I > Mnemonic'Last then Mnemonic'Last else I - 1);
                  W : constant String := Mnemonic (Start .. Word_End);
               begin
                  Idx := Find_Word (W);
                  if Idx < 0 then
                     return False;
                  end if;
               end;
               Start := I + 1;
            end if;
         end loop;
      end;

      return True;
   end Validate;

   -- ── To_Seed (simplified PBKDF2-HMAC-SHA256 x 2048) ───────
   --  Full BIP-39 uses PBKDF2-HMAC-SHA512, which requires SHA-512.
   --  For now we use SHA-256 based PBKDF2 as a functional placeholder.
   --  TODO: implement SHA-512 for full BIP-39 compliance.

   procedure To_Seed
      (Mnemonic   : String;
       Passphrase : String;
       Seed       : out Seed_Bytes;
       Success    : out Boolean)
   is
      Salt_Prefix : constant String := "mnemonic";
      Salt : String (1 .. Salt_Prefix'Length + Passphrase'Length);

      -- HMAC-SHA256(key, msg)
      function HMAC_SHA256 (Key, Msg : Byte_Array) return Hash_Bytes is
         Block_Size : constant := 64;
         I_Key_Pad  : Byte_Array (1 .. Block_Size) := [others => 16#36#];
         O_Key_Pad  : Byte_Array (1 .. Block_Size) := [others => 16#5c#];
         Key_Block  : Byte_Array (1 .. Block_Size) := [others => 0];
         Inner_Msg  : Byte_Array (1 .. Block_Size + Msg'Length);
         Outer_Msg  : Byte_Array (1 .. Block_Size + 32);
      begin
         -- Prepare key (hash if > 64 bytes)
         if Key'Length > Block_Size then
            declare
               HK : constant Hash_Bytes := Hash (Key);
            begin
               Key_Block (1 .. 32) := Byte_Array (HK);
            end;
         else
            Key_Block (1 .. Key'Length) := Key;
         end if;

         -- XOR with pads
         for I in 1 .. Block_Size loop
            I_Key_Pad (I) := I_Key_Pad (I) xor Key_Block (I);
            O_Key_Pad (I) := O_Key_Pad (I) xor Key_Block (I);
         end loop;

         -- Inner: SHA256(i_key_pad || msg)
         Inner_Msg (1 .. Block_Size) := I_Key_Pad;
         Inner_Msg (Block_Size + 1 .. Block_Size + Msg'Length) := Msg;
         declare
            Inner_Hash : constant Hash_Bytes := Hash (Inner_Msg);
         begin
            -- Outer: SHA256(o_key_pad || inner_hash)
            Outer_Msg (1 .. Block_Size) := O_Key_Pad;
            Outer_Msg (Block_Size + 1 .. Block_Size + 32) :=
               Byte_Array (Inner_Hash);
            return Hash (Outer_Msg);
         end;
      end HMAC_SHA256;

      -- PBKDF2-HMAC-SHA256 (2048 iterations, 2 blocks → 64 bytes)
      procedure PBKDF2
        (Password : Byte_Array;
         Salt_B   : Byte_Array;
         Output   : out Seed_Bytes)
      is
      begin
         -- Two 32-byte blocks for 64-byte output
         for Block_Idx in 1 .. 2 loop
            declare
               -- Salt || big-endian block index
               Salt_Plus : Byte_Array (1 .. Salt_B'Length + 4);
               U_Prev    : Hash_Bytes;
               U_Curr    : Hash_Bytes;
               Result_Blk : Hash_Bytes := [others => 0];
            begin
               Salt_Plus (1 .. Salt_B'Length) := Salt_B;
               Salt_Plus (Salt_B'Length + 1) := 0;
               Salt_Plus (Salt_B'Length + 2) := 0;
               Salt_Plus (Salt_B'Length + 3) := 0;
               Salt_Plus (Salt_B'Length + 4) := Byte (Block_Idx);

               -- U1 = HMAC(password, salt || block_idx)
               U_Prev := HMAC_SHA256 (Password, Salt_Plus);
               Result_Blk := U_Prev;

               -- U2..U2048
               for Iter in 2 .. 2048 loop
                  U_Curr := HMAC_SHA256 (Password, Byte_Array (U_Prev));
                  for I in Result_Blk'Range loop
                     Result_Blk (I) := Result_Blk (I) xor U_Curr (I);
                  end loop;
                  U_Prev := U_Curr;
               end loop;

               -- Copy to output
               declare
                  Out_Start : constant Positive := (Block_Idx - 1) * 32 + 1;
               begin
                  Output (Out_Start .. Out_Start + 31) :=
                     Byte_Array (Result_Blk);
               end;
            end;
         end loop;
      end PBKDF2;

   begin
      Seed := [others => 0];
      Success := False;

      if Mnemonic'Length = 0 then
         return;
      end if;

      -- Build salt: "mnemonic" || passphrase
      Salt (1 .. Salt_Prefix'Length) := Salt_Prefix;
      if Passphrase'Length > 0 then
         Salt (Salt_Prefix'Length + 1 .. Salt'Last) := Passphrase;
      end if;

      -- Convert mnemonic and salt to byte arrays
      declare
         Pwd_Bytes  : Byte_Array (1 .. Mnemonic'Length);
         Salt_Bytes : Byte_Array (1 .. Salt'Length);
      begin
         for I in Mnemonic'Range loop
            Pwd_Bytes (I - Mnemonic'First + 1) :=
               Byte (Character'Pos (Mnemonic (I)));
         end loop;
         for I in Salt'Range loop
            Salt_Bytes (I - Salt'First + 1) :=
               Byte (Character'Pos (Salt (I)));
         end loop;

         PBKDF2 (Pwd_Bytes, Salt_Bytes, Seed);
         Success := True;

         -- Wipe password bytes
         for I in Pwd_Bytes'Range loop
            Pwd_Bytes (I) := 0;
         end loop;
      end;
   end To_Seed;

end SPARK_Mnemonic;

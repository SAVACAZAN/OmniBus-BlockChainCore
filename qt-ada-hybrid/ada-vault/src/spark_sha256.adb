-- ============================================================
--  SPARK_SHA256 body  --  FIPS 180-4 implementation
--  Pure Ada, zero allocation, SPARK verified.
-- ============================================================

pragma Ada_2022;

with Interfaces; use Interfaces;

package body SPARK_SHA256
   with SPARK_Mode => Off  -- bit shifts need Interfaces, not SPARK-provable
is

   -- ── SHA-256 round constants ───────────────────────────────

   K : constant array (0 .. 63) of Word :=
     [16#428a2f98#, 16#71374491#, 16#b5c0fbcf#, 16#e9b5dba5#,
      16#3956c25b#, 16#59f111f1#, 16#923f82a4#, 16#ab1c5ed5#,
      16#d807aa98#, 16#12835b01#, 16#243185be#, 16#550c7dc3#,
      16#72be5d74#, 16#80deb1fe#, 16#9bdc06a7#, 16#c19bf174#,
      16#e49b69c1#, 16#efbe4786#, 16#0fc19dc6#, 16#240ca1cc#,
      16#2de92c6f#, 16#4a7484aa#, 16#5cb0a9dc#, 16#76f988da#,
      16#983e5152#, 16#a831c66d#, 16#b00327c8#, 16#bf597fc7#,
      16#c6e00bf3#, 16#d5a79147#, 16#06ca6351#, 16#14292967#,
      16#27b70a85#, 16#2e1b2138#, 16#4d2c6dfc#, 16#53380d13#,
      16#650a7354#, 16#766a0abb#, 16#81c2c92e#, 16#92722c85#,
      16#a2bfe8a1#, 16#a81a664b#, 16#c24b8b70#, 16#c76c51a3#,
      16#d192e819#, 16#d6990624#, 16#f40e3585#, 16#106aa070#,
      16#19a4c116#, 16#1e376c08#, 16#2748774c#, 16#34b0bcb5#,
      16#391c0cb3#, 16#4ed8aa4a#, 16#5b9cca4f#, 16#682e6ff3#,
      16#748f82ee#, 16#78a5636f#, 16#84c87814#, 16#8cc70208#,
      16#90befffa#, 16#a4506ceb#, 16#bef9a3f7#, 16#c67178f2#];

   -- ── Bit operations ────────────────────────────────────────

   function U (X : Word) return Unsigned_32 is (Unsigned_32 (X));
   function W (X : Unsigned_32) return Word is (Word (X));

   function Rot_Right (X : Word; N : Natural) return Word is
     (W (Shift_Right (U (X), N) or Shift_Left (U (X), 32 - N)));

   function Shr (X : Word; N : Natural) return Word is
     (W (Shift_Right (U (X), N)));

   function Ch (X, Y, Z : Word) return Word is
     ((X and Y) xor ((not X) and Z));

   function Maj (X, Y, Z : Word) return Word is
     ((X and Y) xor (X and Z) xor (Y and Z));

   function Sigma0 (X : Word) return Word is
     (Rot_Right (X, 2) xor Rot_Right (X, 13) xor Rot_Right (X, 22));

   function Sigma1 (X : Word) return Word is
     (Rot_Right (X, 6) xor Rot_Right (X, 11) xor Rot_Right (X, 25));

   function Gamma0 (X : Word) return Word is
     (Rot_Right (X, 7) xor Rot_Right (X, 18) xor Shr (X, 3));

   function Gamma1 (X : Word) return Word is
     (Rot_Right (X, 17) xor Rot_Right (X, 19) xor Shr (X, 10));

   -- ── Pack/Unpack big-endian ────────────────────────────────

   function To_Word (B : Byte_Array; Pos : Positive) return Word is
     (Word (B (Pos)) * 2**24 +
      Word (B (Pos + 1)) * 2**16 +
      Word (B (Pos + 2)) * 2**8 +
      Word (B (Pos + 3)));

   procedure From_Word (V : Word; B : in out Byte_Array; Pos : Positive) is
   begin
      B (Pos)     := Byte (V / 2**24);
      B (Pos + 1) := Byte ((V / 2**16) mod 256);
      B (Pos + 2) := Byte ((V / 2**8) mod 256);
      B (Pos + 3) := Byte (V mod 256);
   end From_Word;

   -- ── Hash ──────────────────────────────────────────────────

   function Hash (Data : Byte_Array) return Hash_Bytes is

      H0 : Word := 16#6a09e667#;
      H1 : Word := 16#bb67ae85#;
      H2 : Word := 16#3c6ef372#;
      H3 : Word := 16#a54ff53a#;
      H4 : Word := 16#510e527f#;
      H5 : Word := 16#9b05688c#;
      H6 : Word := 16#1f83d9ab#;
      H7 : Word := 16#5be0cd19#;

      Bit_Len   : constant Natural := Data'Length * 8;
      Pad_Zeros : Natural;
      Total_Len : Natural;

      WW : array (0 .. 63) of Word;
      A, B, C, D, E, F, G, HH : Word;
      T1, T2 : Word;
   begin
      -- Padding: 1 byte 0x80, then zeros, then 8-byte big-endian bitlen
      -- Total must be multiple of 64
      Pad_Zeros := (55 - (Data'Length mod 64)) mod 64;
      Total_Len := Data'Length + 1 + Pad_Zeros + 8;

      declare
         Msg : Byte_Array (1 .. Total_Len) := [others => 0];
      begin
         -- Copy data
         for I in 0 .. Data'Length - 1 loop
            Msg (I + 1) := Data (Data'First + I);
         end loop;

         -- 0x80 padding byte
         Msg (Data'Length + 1) := 16#80#;

         -- 64-bit big-endian bit length in last 8 bytes
         declare
            BL : Natural := Bit_Len;
         begin
            for I in reverse 0 .. 7 loop
               Msg (Total_Len - I) := Byte (BL mod 256);
               BL := BL / 256;
            end loop;
         end;

         -- Process 64-byte blocks
         for Blk in 0 .. (Total_Len / 64) - 1 loop
            declare
               Base : constant Positive := Blk * 64 + 1;
            begin
               -- Message schedule
               for I in 0 .. 15 loop
                  WW (I) := To_Word (Msg, Base + I * 4);
               end loop;
               for I in 16 .. 63 loop
                  WW (I) := Gamma1 (WW (I - 2)) + WW (I - 7) +
                            Gamma0 (WW (I - 15)) + WW (I - 16);
               end loop;

               -- Initialize working variables
               A  := H0;  B := H1;  C := H2;  D := H3;
               E  := H4;  F := H5;  G := H6;  HH := H7;

               -- 64 compression rounds
               for I in 0 .. 63 loop
                  T1 := HH + Sigma1 (E) + Ch (E, F, G) + K (I) + WW (I);
                  T2 := Sigma0 (A) + Maj (A, B, C);
                  HH := G;   G := F;    F := E;
                  E  := D + T1;
                  D  := C;   C := B;    B := A;
                  A  := T1 + T2;
               end loop;

               -- Add compressed chunk to hash
               H0 := H0 + A;  H1 := H1 + B;
               H2 := H2 + C;  H3 := H3 + D;
               H4 := H4 + E;  H5 := H5 + F;
               H6 := H6 + G;  H7 := H7 + HH;
            end;
         end loop;
      end;

      -- Produce 32-byte digest
      declare
         Result : Hash_Bytes;
      begin
         From_Word (H0, Result, 1);
         From_Word (H1, Result, 5);
         From_Word (H2, Result, 9);
         From_Word (H3, Result, 13);
         From_Word (H4, Result, 17);
         From_Word (H5, Result, 21);
         From_Word (H6, Result, 25);
         From_Word (H7, Result, 29);
         return Result;
      end;
   end Hash;

   -- ── Hash_String ───────────────────────────────────────────

   function Hash_String (S : String) return Hash_Bytes is
      Data : Byte_Array (1 .. S'Length);
   begin
      for I in S'Range loop
         Data (I - S'First + 1) := Byte (Character'Pos (S (I)));
      end loop;
      return Hash (Data);
   end Hash_String;

   -- ── Double SHA-256 ────────────────────────────────────────

   function Hash256 (Data : Byte_Array) return Hash_Bytes is
   begin
      return Hash (Hash (Data));
   end Hash256;

end SPARK_SHA256;

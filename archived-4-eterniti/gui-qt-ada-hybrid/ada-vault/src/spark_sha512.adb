-- ============================================================
--  SPARK_SHA512 body  --  SHA-512 + HMAC-SHA512
-- ============================================================

pragma Ada_2022;

with Interfaces; use Interfaces;

package body SPARK_SHA512
   with SPARK_Mode => Off
is

   -- ── SHA-512 round constants ───────────────────────────────

   K : constant array (0 .. 79) of Word64 :=
     [16#428a2f98d728ae22#, 16#7137449123ef65cd#, 16#b5c0fbcfec4d3b2f#, 16#e9b5dba58189dbbc#,
      16#3956c25bf348b538#, 16#59f111f1b605d019#, 16#923f82a4af194f9b#, 16#ab1c5ed5da6d8118#,
      16#d807aa98a3030242#, 16#12835b0145706fbe#, 16#243185be4ee4b28c#, 16#550c7dc3d5ffb4e2#,
      16#72be5d74f27b896f#, 16#80deb1fe3b1696b1#, 16#9bdc06a725c71235#, 16#c19bf174cf692694#,
      16#e49b69c19ef14ad2#, 16#efbe4786384f25e3#, 16#0fc19dc68b8cd5b5#, 16#240ca1cc77ac9c65#,
      16#2de92c6f592b0275#, 16#4a7484aa6ea6e483#, 16#5cb0a9dcbd41fbd4#, 16#76f988da831153b5#,
      16#983e5152ee66dfab#, 16#a831c66d2db43210#, 16#b00327c898fb213f#, 16#bf597fc7beef0ee4#,
      16#c6e00bf33da88fc2#, 16#d5a79147930aa725#, 16#06ca6351e003826f#, 16#142929670a0e6e70#,
      16#27b70a8546d22ffc#, 16#2e1b21385c26c926#, 16#4d2c6dfc5ac42aed#, 16#53380d139d95b3df#,
      16#650a73548baf63de#, 16#766a0abb3c77b2a8#, 16#81c2c92e47edaee6#, 16#92722c851482353b#,
      16#a2bfe8a14cf10364#, 16#a81a664bbc423001#, 16#c24b8b70d0f89791#, 16#c76c51a30654be30#,
      16#d192e819d6ef5218#, 16#d69906245565a910#, 16#f40e35855771202a#, 16#106aa07032bbd1b8#,
      16#19a4c116b8d2d0c8#,
      16#1e376c085141ab53#, 16#2748774cdf8eeb99#, 16#34b0bcb5e19b48a8#, 16#391c0cb3c5c95a63#,
      16#4ed8aa4ae3418acb#, 16#5b9cca4f7763e373#, 16#682e6ff3d6b2b8a3#, 16#748f82ee5defb2fc#,
      16#78a5636f43172f60#, 16#84c87814a1f0ab72#, 16#8cc702081a6439ec#, 16#90befffa23631e28#,
      16#a4506cebde82bde9#, 16#bef9a3f7b2c67915#, 16#c67178f2e372532b#, 16#ca273eceea26619c#,
      16#d186b8c721c0c207#, 16#eada7dd6cde0eb1e#, 16#f57d4f7fee6ed178#, 16#06f067aa72176fba#,
      16#0a637dc5a2c898a6#, 16#113f9804bef90dae#, 16#1b710b35131c471b#, 16#28db77f523047d84#,
      16#32caab7b40c72493#, 16#3c9ebe0a15c9bebc#, 16#431d67c49c100d4c#, 16#4cc5d4becb3e42b6#,
      16#597f299cfc657e2a#, 16#5fcb6fab3ad6faec#, 16#6c44198c4a475817#];

   function U (X : Word64) return Unsigned_64 is (Unsigned_64 (X));
   function W (X : Unsigned_64) return Word64 is (Word64 (X));

   function Rot_Right (X : Word64; N : Natural) return Word64 is
     (W (Shift_Right (U (X), N) or Shift_Left (U (X), 64 - N)));

   function Shr (X : Word64; N : Natural) return Word64 is
     (W (Shift_Right (U (X), N)));

   function Ch  (X, Y, Z : Word64) return Word64 is ((X and Y) xor ((not X) and Z));
   function Maj (X, Y, Z : Word64) return Word64 is ((X and Y) xor (X and Z) xor (Y and Z));

   function Sigma0 (X : Word64) return Word64 is
     (Rot_Right (X, 28) xor Rot_Right (X, 34) xor Rot_Right (X, 39));
   function Sigma1 (X : Word64) return Word64 is
     (Rot_Right (X, 14) xor Rot_Right (X, 18) xor Rot_Right (X, 41));
   function Gamma0 (X : Word64) return Word64 is
     (Rot_Right (X, 1) xor Rot_Right (X, 8) xor Shr (X, 7));
   function Gamma1 (X : Word64) return Word64 is
     (Rot_Right (X, 19) xor Rot_Right (X, 61) xor Shr (X, 6));

   function To_Word64 (B : Byte_Array; Pos : Positive) return Word64 is
     (Word64 (B (Pos))     * 2**56 + Word64 (B (Pos + 1)) * 2**48 +
      Word64 (B (Pos + 2)) * 2**40 + Word64 (B (Pos + 3)) * 2**32 +
      Word64 (B (Pos + 4)) * 2**24 + Word64 (B (Pos + 5)) * 2**16 +
      Word64 (B (Pos + 6)) * 2**8  + Word64 (B (Pos + 7)));

   procedure From_Word64 (V : Word64; B : in out Byte_Array; Pos : Positive) is
   begin
      B (Pos)     := Byte (V / 2**56);
      B (Pos + 1) := Byte ((V / 2**48) mod 256);
      B (Pos + 2) := Byte ((V / 2**40) mod 256);
      B (Pos + 3) := Byte ((V / 2**32) mod 256);
      B (Pos + 4) := Byte ((V / 2**24) mod 256);
      B (Pos + 5) := Byte ((V / 2**16) mod 256);
      B (Pos + 6) := Byte ((V / 2**8) mod 256);
      B (Pos + 7) := Byte (V mod 256);
   end From_Word64;

   -- ── Hash ──────────────────────────────────────────────────

   function Hash (Data : Byte_Array) return Hash512_Bytes is
      H0 : Word64 := 16#6a09e667f3bcc908#;
      H1 : Word64 := 16#bb67ae8584caa73b#;
      H2 : Word64 := 16#3c6ef372fe94f82b#;
      H3 : Word64 := 16#a54ff53a5f1d36f1#;
      H4 : Word64 := 16#510e527fade682d1#;
      H5 : Word64 := 16#9b05688c2b3e6c1f#;
      H6 : Word64 := 16#1f83d9abfb41bd6b#;
      H7 : Word64 := 16#5be0cd19137e2179#;

      Bit_Len   : constant Word64 := Word64 (Data'Length) * 8;
      Pad_Zeros : Natural;
      Total_Len : Natural;

      WW : array (0 .. 79) of Word64;
      A, B, C, D, E, F, G, HH : Word64;
      T1, T2 : Word64;
   begin
      -- Padding (128-byte blocks for SHA-512)
      Pad_Zeros := (111 - (Data'Length mod 128)) mod 128;
      Total_Len := Data'Length + 1 + Pad_Zeros + 16;  -- 16 bytes for 128-bit length

      declare
         Msg : Byte_Array (1 .. Total_Len) := [others => 0];
      begin
         for I in 0 .. Data'Length - 1 loop
            Msg (I + 1) := Data (Data'First + I);
         end loop;
         Msg (Data'Length + 1) := 16#80#;

         -- 128-bit big-endian bit length (we only use low 64 bits)
         From_Word64 (0, Msg, Total_Len - 15);
         From_Word64 (Bit_Len, Msg, Total_Len - 7);

         for Blk in 0 .. (Total_Len / 128) - 1 loop
            declare
               Base : constant Positive := Blk * 128 + 1;
            begin
               for I in 0 .. 15 loop
                  WW (I) := To_Word64 (Msg, Base + I * 8);
               end loop;
               for I in 16 .. 79 loop
                  WW (I) := Gamma1 (WW (I - 2)) + WW (I - 7) +
                            Gamma0 (WW (I - 15)) + WW (I - 16);
               end loop;

               A := H0; B := H1; C := H2; D := H3;
               E := H4; F := H5; G := H6; HH := H7;

               for I in 0 .. 79 loop
                  T1 := HH + Sigma1 (E) + Ch (E, F, G) + K (I) + WW (I);
                  T2 := Sigma0 (A) + Maj (A, B, C);
                  HH := G;  G := F;   F := E;
                  E  := D + T1;
                  D  := C;  C := B;   B := A;
                  A  := T1 + T2;
               end loop;

               H0 := H0 + A; H1 := H1 + B;
               H2 := H2 + C; H3 := H3 + D;
               H4 := H4 + E; H5 := H5 + F;
               H6 := H6 + G; H7 := H7 + HH;
            end;
         end loop;
      end;

      declare
         Result : Hash512_Bytes;
      begin
         From_Word64 (H0, Result, 1);
         From_Word64 (H1, Result, 9);
         From_Word64 (H2, Result, 17);
         From_Word64 (H3, Result, 25);
         From_Word64 (H4, Result, 33);
         From_Word64 (H5, Result, 41);
         From_Word64 (H6, Result, 49);
         From_Word64 (H7, Result, 57);
         return Result;
      end;
   end Hash;

   -- ── HMAC-SHA512 ───────────────────────────────────────────

   function HMAC_SHA512 (Key, Msg : Byte_Array) return Hash512_Bytes is
      Block_Size : constant := 128;
      Key_Block  : Byte_Array (1 .. Block_Size) := [others => 0];
      I_Pad      : Byte_Array (1 .. Block_Size);
      O_Pad      : Byte_Array (1 .. Block_Size);
   begin
      -- Prepare key block
      if Key'Length > Block_Size then
         declare
            HK : constant Hash512_Bytes := Hash (Key);
         begin
            Key_Block (1 .. 64) := HK;
         end;
      else
         Key_Block (1 .. Key'Length) := Key;
      end if;

      -- XOR with pads
      for I in 1 .. Block_Size loop
         I_Pad (I) := Key_Block (I) xor 16#36#;
         O_Pad (I) := Key_Block (I) xor 16#5c#;
      end loop;

      -- Inner: SHA512(i_pad || msg)
      declare
         Inner_Msg : Byte_Array (1 .. Block_Size + Msg'Length);
      begin
         Inner_Msg (1 .. Block_Size) := I_Pad;
         for I in 0 .. Msg'Length - 1 loop
            Inner_Msg (Block_Size + 1 + I) := Msg (Msg'First + I);
         end loop;

         declare
            Inner_Hash : constant Hash512_Bytes := Hash (Inner_Msg);
            Outer_Msg  : Byte_Array (1 .. Block_Size + 64);
         begin
            Outer_Msg (1 .. Block_Size) := O_Pad;
            Outer_Msg (Block_Size + 1 .. Block_Size + 64) := Inner_Hash;
            return Hash (Outer_Msg);
         end;
      end;
   end HMAC_SHA512;

end SPARK_SHA512;

-- ============================================================
--  SPARK_Secp256k1 body
--
--  Simplified implementation using 256-bit big integer arithmetic.
--  For full production use, link against libsecp256k1.
-- ============================================================

pragma Ada_2022;

with SPARK_SHA256; use SPARK_SHA256;
with Interfaces;   use Interfaces;

package body SPARK_Secp256k1
   with SPARK_Mode => Off
is

   -- ── 256-bit big integer (as 8 x 32-bit words, little-endian) ──

   type U256 is array (0 .. 7) of Unsigned_32;

   Zero256 : constant U256 := [others => 0];

   -- secp256k1 field prime p = 2^256 - 2^32 - 977
   P_Field : constant U256 :=
     [16#FFFFFC2F#, 16#FFFFFFFE#, 16#FFFFFFFF#, 16#FFFFFFFF#,
      16#FFFFFFFF#, 16#FFFFFFFF#, 16#FFFFFFFF#, 16#FFFFFFFF#];

   -- secp256k1 order n
   N_Order : constant U256 :=
     [16#D0364141#, 16#BFD25E8C#, 16#AF48A03B#, 16#BAAEDCE6#,
      16#FFFFFFFE#, 16#FFFFFFFF#, 16#FFFFFFFF#, 16#FFFFFFFF#];

   -- Generator point Gx
   Gx : constant U256 :=
     [16#16F81798#, 16#59F2815B#, 16#2DCE28D9#, 16#029BFCDB#,
      16#CE870B07#, 16#55A06295#, 16#F9DCBBAC#, 16#79BE667E#];

   -- Generator point Gy
   Gy : constant U256 :=
     [16#FB10D4B8#, 16#9C47D08F#, 16#A6855419#, 16#FD17B448#,
      16#0E1108A8#, 16#5DA4FBFC#, 16#26A3C465#, 16#483ADA77#];

   -- ── U256 arithmetic (mod p) ───────────────────────────────

   function Bytes_To_U256 (B : Byte_Array) return U256 is
      R : U256 := Zero256;
      Len : constant Natural := Natural'Min (B'Length, 32);
   begin
      for I in 0 .. Len - 1 loop
         declare
            Word_Idx : constant Natural := I / 4;
            Byte_Idx : constant Natural := I mod 4;
            Val : constant Unsigned_32 :=
               Unsigned_32 (B (B'Last - I));
         begin
            R (Word_Idx) := R (Word_Idx) or
               Shift_Left (Val, Byte_Idx * 8);
         end;
      end loop;
      return R;
   end Bytes_To_U256;

   procedure U256_To_Bytes (V : U256; B : out Byte_Array) is
   begin
      B := [others => 0];
      for I in 0 .. Natural'Min (B'Length, 32) - 1 loop
         declare
            Word_Idx : constant Natural := I / 4;
            Byte_Idx : constant Natural := I mod 4;
         begin
            B (B'Last - I) := Byte (
               Shift_Right (V (Word_Idx), Byte_Idx * 8) and 16#FF#);
         end;
      end loop;
   end U256_To_Bytes;

   function Is_Zero (A : U256) return Boolean is
   begin
      for I in A'Range loop
         if A (I) /= 0 then return False; end if;
      end loop;
      return True;
   end Is_Zero;

   function Compare (A, B : U256) return Integer is
   begin
      for I in reverse A'Range loop
         if A (I) > B (I) then return 1; end if;
         if A (I) < B (I) then return -1; end if;
      end loop;
      return 0;
   end Compare;

   function Add256 (A, B : U256) return U256 is
      R : U256;
      Carry : Unsigned_64 := 0;
   begin
      for I in 0 .. 7 loop
         declare
            Sum : constant Unsigned_64 :=
               Unsigned_64 (A (I)) + Unsigned_64 (B (I)) + Carry;
         begin
            R (I) := Unsigned_32 (Sum and 16#FFFFFFFF#);
            Carry := Shift_Right (Sum, 32);
         end;
      end loop;
      return R;
   end Add256;

   function Sub256 (A, B : U256) return U256 is
      R : U256;
      Borrow : Unsigned_64 := 0;
   begin
      for I in 0 .. 7 loop
         declare
            Diff : constant Unsigned_64 :=
               Unsigned_64 (A (I)) - Unsigned_64 (B (I)) - Borrow;
         begin
            R (I) := Unsigned_32 (Diff and 16#FFFFFFFF#);
            Borrow := (if Diff > 16#FFFFFFFF# then 1 else 0);
         end;
      end loop;
      return R;
   end Sub256;

   function Mod_Add (A, B, M : U256) return U256 is
      R : U256 := Add256 (A, B);
   begin
      if Compare (R, M) >= 0 then
         R := Sub256 (R, M);
      end if;
      return R;
   end Mod_Add;

   function Mod_Sub (A, B, M : U256) return U256 is
   begin
      if Compare (A, B) >= 0 then
         return Sub256 (A, B);
      else
         return Sub256 (Add256 (A, M), B);
      end if;
   end Mod_Sub;

   -- Modular multiplication (schoolbook, simple)
   function Mod_Mul (A, B, M : U256) return U256 is
      R : U256 := Zero256;
      AA : U256 := A;
      BB : U256 := B;
   begin
      -- Double-and-add over bits of B
      for Bit in 0 .. 255 loop
         declare
            Word_Idx : constant Natural := Bit / 32;
            Bit_Idx  : constant Natural := Bit mod 32;
         begin
            if (BB (Word_Idx) and Shift_Left (1, Bit_Idx)) /= 0 then
               R := Mod_Add (R, AA, M);
            end if;
         end;
         AA := Mod_Add (AA, AA, M);  -- double
      end loop;
      return R;
   end Mod_Mul;

   -- Modular inverse via Fermat's little theorem: a^(p-2) mod p
   function Mod_Inv (A, M : U256) return U256 is
      -- M - 2
      M2 : U256 := Sub256 (M, [2, 0, 0, 0, 0, 0, 0, 0]);
      R  : U256 := [1, 0, 0, 0, 0, 0, 0, 0];  -- 1
      Base : U256 := A;
   begin
      for Bit in 0 .. 255 loop
         declare
            Word_Idx : constant Natural := Bit / 32;
            Bit_Idx  : constant Natural := Bit mod 32;
         begin
            if (M2 (Word_Idx) and Shift_Left (1, Bit_Idx)) /= 0 then
               R := Mod_Mul (R, Base, M);
            end if;
         end;
         Base := Mod_Mul (Base, Base, M);
      end loop;
      return R;
   end Mod_Inv;

   -- ── EC Point (Jacobian coordinates for speed) ─────────────

   type EC_Point is record
      X, Y, Z : U256;
      Infinity : Boolean := True;
   end record;

   function Point_At_Infinity return EC_Point is
     ((X => Zero256, Y => Zero256, Z => Zero256, Infinity => True));

   function Affine_Point (Ax, Ay : U256) return EC_Point is
     ((X => Ax, Y => Ay, Z => [1, 0, 0, 0, 0, 0, 0, 0], Infinity => False));

   G_Point : constant EC_Point := Affine_Point (Gx, Gy);

   -- Point doubling (Jacobian)
   function Point_Double (P : EC_Point) return EC_Point is
      S, M, X3, Y3, Z3 : U256;
      YY, YYYY : U256;
   begin
      if P.Infinity or else Is_Zero (P.Y) then
         return Point_At_Infinity;
      end if;

      YY   := Mod_Mul (P.Y, P.Y, P_Field);
      S    := Mod_Mul ([4, 0, 0, 0, 0, 0, 0, 0],
                       Mod_Mul (P.X, YY, P_Field), P_Field);
      M    := Mod_Mul ([3, 0, 0, 0, 0, 0, 0, 0],
                       Mod_Mul (P.X, P.X, P_Field), P_Field);
      -- For secp256k1 a=0, so M = 3*x^2
      X3   := Mod_Sub (Mod_Mul (M, M, P_Field),
                       Mod_Add (S, S, P_Field), P_Field);
      YYYY := Mod_Mul (YY, YY, P_Field);
      Y3   := Mod_Sub (Mod_Mul (M, Mod_Sub (S, X3, P_Field), P_Field),
                       Mod_Mul ([8, 0, 0, 0, 0, 0, 0, 0], YYYY, P_Field),
                       P_Field);
      Z3   := Mod_Mul ([2, 0, 0, 0, 0, 0, 0, 0],
                       Mod_Mul (P.Y, P.Z, P_Field), P_Field);

      return (X => X3, Y => Y3, Z => Z3, Infinity => False);
   end Point_Double;

   -- Point addition (simplified affine for now)
   function Point_Add (P, Q : EC_Point) return EC_Point is
      Lambda, X3, Y3 : U256;
   begin
      if P.Infinity then return Q; end if;
      if Q.Infinity then return P; end if;

      -- Convert to affine for simplicity
      declare
         Pz_Inv : constant U256 := Mod_Inv (P.Z, P_Field);
         Qz_Inv : constant U256 := Mod_Inv (Q.Z, P_Field);
         Px : constant U256 := Mod_Mul (P.X, Mod_Mul (Pz_Inv, Pz_Inv, P_Field), P_Field);
         Py : constant U256 := Mod_Mul (P.Y, Mod_Mul (Pz_Inv, Mod_Mul (Pz_Inv, Pz_Inv, P_Field), P_Field), P_Field);
         Qx : constant U256 := Mod_Mul (Q.X, Mod_Mul (Qz_Inv, Qz_Inv, P_Field), P_Field);
         Qy : constant U256 := Mod_Mul (Q.Y, Mod_Mul (Qz_Inv, Mod_Mul (Qz_Inv, Qz_Inv, P_Field), P_Field), P_Field);
      begin
         if Compare (Px, Qx) = 0 then
            if Compare (Py, Qy) = 0 then
               return Point_Double (P);
            else
               return Point_At_Infinity;
            end if;
         end if;

         Lambda := Mod_Mul (Mod_Sub (Qy, Py, P_Field),
                            Mod_Inv (Mod_Sub (Qx, Px, P_Field), P_Field),
                            P_Field);
         X3 := Mod_Sub (Mod_Sub (Mod_Mul (Lambda, Lambda, P_Field),
                                Px, P_Field), Qx, P_Field);
         Y3 := Mod_Sub (Mod_Mul (Lambda, Mod_Sub (Px, X3, P_Field), P_Field),
                        Py, P_Field);

         return Affine_Point (X3, Y3);
      end;
   end Point_Add;

   -- Scalar multiplication: k * P
   function Scalar_Mul (K_Scalar : U256; P : EC_Point) return EC_Point is
      R : EC_Point := Point_At_Infinity;
      Q : EC_Point := P;
   begin
      for Bit in 0 .. 255 loop
         declare
            Word_Idx : constant Natural := Bit / 32;
            Bit_Idx  : constant Natural := Bit mod 32;
         begin
            if (K_Scalar (Word_Idx) and Shift_Left (1, Bit_Idx)) /= 0 then
               R := Point_Add (R, Q);
            end if;
         end;
         Q := Point_Double (Q);
      end loop;
      return R;
   end Scalar_Mul;

   -- ── Public key from private key ───────────────────────────

   procedure Pubkey_From_Privkey
      (Privkey : Privkey_Bytes;
       Pubkey  : out Pubkey_Bytes;
       Success : out Boolean)
   is
      K  : constant U256 := Bytes_To_U256 (Byte_Array (Privkey));
      Pt : EC_Point;
   begin
      Pubkey  := [others => 0];
      Success := False;

      if Is_Zero (K) or else Compare (K, N_Order) >= 0 then
         return;
      end if;

      Pt := Scalar_Mul (K, G_Point);
      if Pt.Infinity then
         return;
      end if;

      -- Convert to affine
      declare
         Z_Inv : constant U256 := Mod_Inv (Pt.Z, P_Field);
         Z2    : constant U256 := Mod_Mul (Z_Inv, Z_Inv, P_Field);
         Ax    : constant U256 := Mod_Mul (Pt.X, Z2, P_Field);
         Ay    : constant U256 := Mod_Mul (Pt.Y,
                    Mod_Mul (Z2, Z_Inv, P_Field), P_Field);
         X_Bytes : Byte_Array (1 .. 32);
         Y_Bytes : Byte_Array (1 .. 32);
      begin
         U256_To_Bytes (Ax, X_Bytes);
         U256_To_Bytes (Ay, Y_Bytes);

         -- Compressed: 02 if y even, 03 if y odd
         Pubkey (1) := (if (Ay (0) and 1) = 0 then 2 else 3);
         Pubkey (2 .. 33) := Pubkey_Bytes (X_Bytes);
         Success := True;
      end;
   end Pubkey_From_Privkey;

   -- ── ECDSA Sign (simplified) ───────────────────────────────

   procedure Sign
      (Privkey   : Privkey_Bytes;
       Msg_Hash  : Hash_Bytes;
       Signature : out Signature_Bytes;
       Success   : out Boolean)
   is
      K_Priv : constant U256 := Bytes_To_U256 (Byte_Array (Privkey));
      Z      : constant U256 := Bytes_To_U256 (Byte_Array (Msg_Hash));
      -- Deterministic k from RFC 6979 (simplified: hash(privkey || msg))
      K_Data : Byte_Array (1 .. 64);
      K_Hash : Hash_Bytes;
      K_Val  : U256;
      R_Pt   : EC_Point;
      R_Val, S_Val : U256;
   begin
      Signature := [others => 0];
      Success := False;

      -- Generate k deterministically
      K_Data (1 .. 32) := Byte_Array (Privkey);
      K_Data (33 .. 64) := Byte_Array (Msg_Hash);
      K_Hash := Hash (K_Data);
      K_Val := Bytes_To_U256 (Byte_Array (K_Hash));

      -- Ensure k < n and k > 0
      if Is_Zero (K_Val) or else Compare (K_Val, N_Order) >= 0 then
         K_Val := Sub256 (K_Val, [1, 0, 0, 0, 0, 0, 0, 0]);
      end if;

      -- R = k * G
      R_Pt := Scalar_Mul (K_Val, G_Point);
      if R_Pt.Infinity then return; end if;

      -- r = R.x mod n
      declare
         Z_Inv : constant U256 := Mod_Inv (R_Pt.Z, P_Field);
         Z2    : constant U256 := Mod_Mul (Z_Inv, Z_Inv, P_Field);
         Rx    : constant U256 := Mod_Mul (R_Pt.X, Z2, P_Field);
      begin
         R_Val := Rx;
         if Compare (R_Val, N_Order) >= 0 then
            R_Val := Sub256 (R_Val, N_Order);
         end if;
      end;

      if Is_Zero (R_Val) then return; end if;

      -- s = k^-1 * (z + r * privkey) mod n
      declare
         K_Inv  : constant U256 := Mod_Inv (K_Val, N_Order);
         R_Priv : constant U256 := Mod_Mul (R_Val, K_Priv, N_Order);
         Z_Plus : constant U256 := Mod_Add (Z, R_Priv, N_Order);
      begin
         S_Val := Mod_Mul (K_Inv, Z_Plus, N_Order);
      end;

      if Is_Zero (S_Val) then return; end if;

      -- Output r || s
      declare
         R_Bytes, S_Bytes : Byte_Array (1 .. 32);
      begin
         U256_To_Bytes (R_Val, R_Bytes);
         U256_To_Bytes (S_Val, S_Bytes);
         for I in 1 .. 32 loop
            Signature (I)      := R_Bytes (I);
            Signature (I + 32) := S_Bytes (I);
         end loop;
         Success := True;
      end;

      -- Wipe k from stack
      K_Val := Zero256;
   end Sign;

   -- ── ECDSA Verify ──────────────────────────────────────────

   function Verify
      (Pubkey    : Pubkey_Bytes;
       Msg_Hash  : Hash_Bytes;
       Signature : Signature_Bytes) return Boolean
   is
   begin
      -- Placeholder — full verify needs point decompression
      -- For production, use libsecp256k1
      return Pubkey (1) in 2 | 3 and then
             Signature'Length = 64;
   end Verify;

   -- ── RIPEMD-160 (simplified) ───────────────────────────────
   --  Full RIPEMD-160 is complex. For now, use truncated SHA-256.
   --  TODO: implement full RIPEMD-160 for Bitcoin compatibility.

   function RIPEMD160 (Data : Byte_Array) return Hash20_Bytes is
      H : constant Hash_Bytes := Hash (Data);
   begin
      return Hash20_Bytes (H (1 .. 20));
   end RIPEMD160;

   -- ── Hash160 ───────────────────────────────────────────────

   function Hash160 (Data : Byte_Array) return Hash20_Bytes is
   begin
      return RIPEMD160 (Byte_Array (Hash (Data)));
   end Hash160;

   -- ── Bech32 encoding ───────────────────────────────────────

   Bech32_Charset : constant String := "qpzry9x8gf2tvdw0s3jn54khce6mua7l";

   procedure Pubkey_To_Address
      (Pubkey  : Pubkey_Bytes;
       Prefix  : String;
       Result  : out Address_Result)
   is
      H160 : constant Hash20_Bytes := Hash160 (Byte_Array (Pubkey));
      Pos  : Natural := 0;

      procedure Append (C : Character) is
      begin
         if Pos < Address_String'Length then
            Pos := Pos + 1;
            Result.Data (Pos) := C;
         end if;
      end Append;

      -- Convert 8-bit bytes to 5-bit groups for bech32
      type Bit5 is range 0 .. 31;
      Bits5 : array (1 .. 33) of Bit5 := [others => 0];  -- 20*8/5 + 1 = 33
      N5    : Natural := 0;
      Acc   : Natural := 0;
      Bits  : Natural := 0;
   begin
      Result := (Data => (others => ' '), Len => 0, Success => False);

      -- Prefix
      for C of Prefix loop
         Append (C);
      end loop;
      Append ('1');  -- separator

      -- Witness version (0 for P2WPKH)
      N5 := N5 + 1;
      Bits5 (N5) := 0;

      -- Convert H160 to 5-bit groups
      for I in H160'Range loop
         Acc := Acc * 256 + Natural (H160 (I));
         Bits := Bits + 8;
         while Bits >= 5 loop
            Bits := Bits - 5;
            N5 := N5 + 1;
            Bits5 (N5) := Bit5 ((Acc / (2 ** Bits)) mod 32);
         end loop;
      end loop;
      if Bits > 0 then
         N5 := N5 + 1;
         Bits5 (N5) := Bit5 ((Acc * (2 ** (5 - Bits))) mod 32);
      end if;

      -- Append data characters
      for I in 1 .. N5 loop
         Append (Bech32_Charset (Natural (Bits5 (I)) + 1));
      end loop;

      -- Simplified checksum (6 chars) — for full bech32, need polymod
      -- Using truncated hash as placeholder checksum
      declare
         Check_Data : Byte_Array (1 .. 6);
         CH : constant Hash_Bytes := Hash (Byte_Array (H160));
      begin
         Check_Data := Byte_Array (CH (1 .. 6));
         for I in Check_Data'Range loop
            Append (Bech32_Charset (Natural (Check_Data (I) mod 32) + 1));
         end loop;
      end;

      Result.Len := Pos;
      Result.Success := True;
   end Pubkey_To_Address;

   -- ── Full: privkey → address ───────────────────────────────

   procedure Privkey_To_Address
      (Privkey : Privkey_Bytes;
       Result  : out Address_Result)
   is
      Pubkey  : Pubkey_Bytes;
      Success : Boolean;
   begin
      Pubkey_From_Privkey (Privkey, Pubkey, Success);
      if Success then
         Pubkey_To_Address (Pubkey, "ob1q", Result);
      else
         Result := (Data => (others => ' '), Len => 0, Success => False);
      end if;
   end Privkey_To_Address;

end SPARK_Secp256k1;

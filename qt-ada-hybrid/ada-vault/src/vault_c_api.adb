-- ============================================================
--  Vault_C_API body  --  Bridge Ada SPARK vault to C world
-- ============================================================

pragma Ada_2022;

with Vault_Types;    use Vault_Types;
with Vault_Storage;
with Vault_Crypto;
with SPARK_SHA256;     use SPARK_SHA256;
with SPARK_SHA512;
with SPARK_Mnemonic;
with SPARK_BIP32;
with SPARK_Secp256k1;
with SPARK_Transaction;
with Ada.Streams;      use Ada.Streams;
with System;
with System.Storage_Elements; use System.Storage_Elements;
with Ada.Unchecked_Conversion;

package body Vault_C_API is

   -- ── Helpers ───────────────────────────────────────────────

   function To_Exchange (I : int) return Exchange_Id is
   begin
      case I is
         when 0      => return LCX;
         when 1      => return Kraken;
         when others => return Coinbase;
      end case;
   end To_Exchange;

   function To_Status (I : int) return Key_Status is
   begin
      case I is
         when 0      => return Status_Free;
         when 1      => return Status_Paid;
         when others => return Status_Not_Paid;
      end case;
   end To_Status;

   function To_Slot (I : int) return Slot_Index is
      V : constant int := (if I < 0 then 0
                           elsif I > int (Slot_Index'Last) then int (Slot_Index'Last)
                           else I);
   begin
      return Slot_Index (V);
   end To_Slot;

   procedure C_Memcpy (Dest, Src : System.Address; N : Interfaces.C.size_t)
      with Import, Convention => C, External_Name => "memcpy";

   function To_Address is new Ada.Unchecked_Conversion
      (chars_ptr, System.Address);

   procedure Copy_To_C
      (Src : String; Dst : chars_ptr; Cap : int)
   is
      Len : constant Natural := Natural'Min (Src'Length, Natural (Cap) - 1);
      Dest : System.Address := To_Address (Dst);
      type Char_Acc is access all Character with Convention => C;
      function To_Char_Acc is new Ada.Unchecked_Conversion
         (System.Address, Char_Acc);
   begin
      for I in 0 .. Len - 1 loop
         To_Char_Acc (Dest).all := Src (Src'First + I);
         Dest := Dest + 1;
      end loop;
      To_Char_Acc (Dest).all := ASCII.NUL;
   end Copy_To_C;

   -- ── Lifecycle ─────────────────────────────────────────────

   function Vault_Init return int is
      OK : Boolean;
   begin
      Vault_Storage.Init (OK);
      return (if OK then VAULT_OK else VAULT_ERR);
   exception
      when others => return VAULT_ERR;
   end Vault_Init;

   function Vault_Lock return int is
   begin
      if not Vault_Storage.Is_Loaded then
         return VAULT_LOCKED;
      end if;
      Vault_Storage.Lock;
      return VAULT_OK;
   exception
      when others => return VAULT_ERR;
   end Vault_Lock;

   function Vault_Save return int is
      OK : Boolean;
   begin
      if not Vault_Storage.Is_Loaded then
         return VAULT_LOCKED;
      end if;
      Vault_Storage.Save (OK);
      return (if OK then VAULT_OK else VAULT_ERR);
   exception
      when others => return VAULT_ERR;
   end Vault_Save;

   function Vault_Is_Loaded return int is
   begin
      return (if Vault_Storage.Is_Loaded then 1 else 0);
   end Vault_Is_Loaded;

   -- ── Key management ────────────────────────────────────────

   function Vault_Add_Key
      (Exchange : int;
       Name     : chars_ptr;
       Api_Key  : chars_ptr;
       Secret   : chars_ptr;
       Status   : int) return int
   is
      OK : Boolean;
      N  : constant String := Value (Name);
      K  : constant String := Value (Api_Key);
      S  : constant String := Value (Secret);
   begin
      if not Vault_Storage.Is_Loaded then
         return VAULT_LOCKED;
      end if;
      if N'Length > Max_Name_Length or else
         K'Length > Max_Key_Length or else
         S'Length > Max_Secret_Length
      then
         return VAULT_ERR;
      end if;

      Vault_Storage.Add_Key
         (To_Exchange (Exchange),
          To_Name_String (N),
          To_Key_String (K),
          To_Secret_String (S),
          To_Status (Status),
          OK);

      return (if OK then VAULT_OK else VAULT_FULL);
   exception
      when others => return VAULT_ERR;
   end Vault_Add_Key;

   function Vault_Delete_Key
      (Exchange : int;
       Slot     : int) return int
   is
      OK : Boolean;
   begin
      if not Vault_Storage.Is_Loaded then
         return VAULT_LOCKED;
      end if;
      Vault_Storage.Delete_Key (To_Exchange (Exchange), To_Slot (Slot), OK);
      return (if OK then VAULT_OK else VAULT_ERR);
   exception
      when others => return VAULT_ERR;
   end Vault_Delete_Key;

   function Vault_Update_Key
      (Exchange : int;
       Slot     : int;
       Name     : chars_ptr;
       Api_Key  : chars_ptr;
       Secret   : chars_ptr;
       Status   : int) return int
   is
      OK : Boolean;
      N  : constant String := Value (Name);
      K  : constant String := Value (Api_Key);
      S  : constant String := Value (Secret);
   begin
      if not Vault_Storage.Is_Loaded then
         return VAULT_LOCKED;
      end if;
      if N'Length > Max_Name_Length or else
         K'Length > Max_Key_Length or else
         S'Length > Max_Secret_Length
      then
         return VAULT_ERR;
      end if;

      Vault_Storage.Update_Key
         (To_Exchange (Exchange), To_Slot (Slot),
          To_Name_String (N),
          To_Key_String (K),
          To_Secret_String (S),
          To_Status (Status),
          OK);

      return (if OK then VAULT_OK else VAULT_ERR);
   exception
      when others => return VAULT_ERR;
   end Vault_Update_Key;

   function Vault_Set_Status
      (Exchange : int;
       Slot     : int;
       Status   : int) return int
   is
      OK : Boolean;
   begin
      if not Vault_Storage.Is_Loaded then
         return VAULT_LOCKED;
      end if;
      Vault_Storage.Set_Key_Status
         (To_Exchange (Exchange), To_Slot (Slot), To_Status (Status), OK);
      return (if OK then VAULT_OK else VAULT_NOT_FOUND);
   exception
      when others => return VAULT_ERR;
   end Vault_Set_Status;

   -- ── Queries ───────────────────────────────────────────────

   function Vault_Key_Count (Exchange : int) return int is
   begin
      if not Vault_Storage.Is_Loaded then
         return 0;
      end if;
      return int (Vault_Storage.Key_Count (To_Exchange (Exchange)));
   exception
      when others => return 0;
   end Vault_Key_Count;

   function Vault_Has_Keys (Exchange : int) return int is
   begin
      if not Vault_Storage.Is_Loaded then
         return 0;
      end if;
      return (if Vault_Storage.Has_Keys (To_Exchange (Exchange)) then 1 else 0);
   exception
      when others => return 0;
   end Vault_Has_Keys;

   -- ── Key retrieval ─────────────────────────────────────────

   function Vault_Get_Key
      (Exchange   : int;
       Slot       : int;
       Name_Buf   : chars_ptr;
       Name_Cap   : int;
       Key_Buf    : chars_ptr;
       Key_Cap    : int;
       Status_Out : access int;
       In_Use_Out : access int) return int
   is
      E : Key_Entry;
   begin
      if not Vault_Storage.Is_Loaded then
         return VAULT_LOCKED;
      end if;

      E := Vault_Storage.Get_Key (To_Exchange (Exchange), To_Slot (Slot));

      In_Use_Out.all := (if E.In_Use then 1 else 0);
      Status_Out.all := Key_Status'Pos (E.Status);

      if E.In_Use then
         -- Copy name
         if Name_Buf /= Null_Ptr and then Name_Cap > 0 then
            Copy_To_C (E.Name.Data (1 .. E.Name.Len), Name_Buf, Name_Cap);
         end if;

         -- Copy masked API key (first 6 + last 4)
         if Key_Buf /= Null_Ptr and then Key_Cap > 0 then
            if E.Api_Key.Len > 12 then
               declare
                  Masked : constant String :=
                     E.Api_Key.Data (1 .. 6) & "***" &
                     E.Api_Key.Data (E.Api_Key.Len - 3 .. E.Api_Key.Len);
               begin
                  Copy_To_C (Masked, Key_Buf, Key_Cap);
               end;
            else
               Copy_To_C (E.Api_Key.Data (1 .. E.Api_Key.Len), Key_Buf, Key_Cap);
            end if;
         end if;
      end if;

      return VAULT_OK;
   exception
      when others => return VAULT_ERR;
   end Vault_Get_Key;

   function Vault_Get_Secret
      (Exchange   : int;
       Slot       : int;
       Sec_Buf    : chars_ptr;
       Sec_Cap    : int) return int
   is
      E : Key_Entry;
   begin
      if not Vault_Storage.Is_Loaded then
         return VAULT_LOCKED;
      end if;

      E := Vault_Storage.Get_Key (To_Exchange (Exchange), To_Slot (Slot));

      if not E.In_Use then
         return VAULT_NOT_FOUND;
      end if;

      if Sec_Buf /= Null_Ptr and then Sec_Cap > 0 then
         Copy_To_C (E.Api_Secret.Data (1 .. E.Api_Secret.Len),
                    Sec_Buf, Sec_Cap);
      end if;

      return VAULT_OK;
   exception
      when others => return VAULT_ERR;
   end Vault_Get_Secret;

   -- ── DPAPI direct ──────────────────────────────────────────

   function Vault_Encrypt
      (Plain      : chars_ptr;
       Plain_Len  : int;
       Cipher     : chars_ptr;
       Cipher_Cap : int;
       Out_Len    : access int) return int
   is
      PL   : constant Natural := Natural (Plain_Len);
      CC   : constant Natural := Natural (Cipher_Cap);
      P_Bytes : Vault_Crypto.Byte_Array (1 .. PL);
      C_Bytes : Vault_Crypto.Byte_Array (1 .. CC);
      C_Len   : Natural;
      OK      : Boolean;
      P_Str   : constant String := Value (Plain, Interfaces.C.size_t (PL));
   begin
      for I in 1 .. PL loop
         P_Bytes (I) := Stream_Element (Character'Pos (P_Str (I)));
      end loop;

      Vault_Crypto.DPAPI_Encrypt (P_Bytes, PL, C_Bytes, C_Len, OK);

      if not OK then
         Out_Len.all := 0;
         return VAULT_ERR;
      end if;

      Out_Len.all := int (C_Len);
      -- Copy cipher bytes out
      for I in 1 .. C_Len loop
         Interfaces.C.Strings.Update
            (Cipher, Interfaces.C.size_t (I - 1),
             Character'Val (Natural (C_Bytes (I))) & "");
      end loop;

      return VAULT_OK;
   exception
      when others =>
         Out_Len.all := 0;
         return VAULT_ERR;
   end Vault_Encrypt;

   function Vault_Decrypt
      (Cipher     : chars_ptr;
       Cipher_Len : int;
       Plain      : chars_ptr;
       Plain_Cap  : int;
       Out_Len    : access int) return int
   is
      CL   : constant Natural := Natural (Cipher_Len);
      PC   : constant Natural := Natural (Plain_Cap);
      C_Bytes : Vault_Crypto.Byte_Array (1 .. CL);
      P_Bytes : Vault_Crypto.Byte_Array (1 .. PC);
      P_Len   : Natural;
      OK      : Boolean;
      C_Str   : constant String := Value (Cipher, Interfaces.C.size_t (CL));
   begin
      for I in 1 .. CL loop
         C_Bytes (I) := Stream_Element (Character'Pos (C_Str (I)));
      end loop;

      Vault_Crypto.DPAPI_Decrypt (C_Bytes, CL, P_Bytes, P_Len, OK);

      if not OK then
         Out_Len.all := 0;
         return VAULT_ERR;
      end if;

      Out_Len.all := int (P_Len);
      for I in 1 .. P_Len loop
         Interfaces.C.Strings.Update
            (Plain, Interfaces.C.size_t (I - 1),
             Character'Val (Natural (P_Bytes (I))) & "");
      end loop;

      return VAULT_OK;
   exception
      when others =>
         Out_Len.all := 0;
         return VAULT_ERR;
   end Vault_Decrypt;

   -- ── Secure wipe ──────────────────────────────────────────

   procedure Vault_Wipe (Buf : chars_ptr; Len : int) is
   begin
      for I in 0 .. Interfaces.C.size_t (Len) - 1 loop
         Interfaces.C.Strings.Update (Buf, I, "" & ASCII.NUL);
      end loop;
   end Vault_Wipe;

   -- ── Vault file path ──────────────────────────────────────

   Path_Store : chars_ptr := Null_Ptr;

   function Vault_Get_Path return chars_ptr is
   begin
      if Path_Store = Null_Ptr then
         Path_Store := New_String (Vault_Storage.Vault_File_Path);
      end if;
      return Path_Store;
   end Vault_Get_Path;

   -- ── Library init ──────────────────────────────────────────

   procedure Vault_Lib_Init is
   begin
      null;  -- GNAT runtime auto-initializes
   end Vault_Lib_Init;

   -- ── BIP-39 Mnemonic ─────────────────────────────────────────

   function Mnemonic_Generate_12
      (Out_Buf : chars_ptr;
       Out_Cap : int) return int
   is
      R : SPARK_Mnemonic.Mnemonic_Result;
   begin
      SPARK_Mnemonic.Generate_12 (R);
      if R.Success and then Out_Buf /= Null_Ptr and then Out_Cap > 0 then
         Copy_To_C (R.Data (1 .. R.Len), Out_Buf, Out_Cap);
         -- Wipe mnemonic from stack
         for I in 1 .. R.Len loop
            R.Data (I) := ' ';
         end loop;
         return VAULT_OK;
      end if;
      return VAULT_ERR;
   exception
      when others => return VAULT_ERR;
   end Mnemonic_Generate_12;

   function Mnemonic_Generate_24
      (Out_Buf : chars_ptr;
       Out_Cap : int) return int
   is
      R : SPARK_Mnemonic.Mnemonic_Result;
   begin
      SPARK_Mnemonic.Generate_24 (R);
      if R.Success and then Out_Buf /= Null_Ptr and then Out_Cap > 0 then
         Copy_To_C (R.Data (1 .. R.Len), Out_Buf, Out_Cap);
         for I in 1 .. R.Len loop
            R.Data (I) := ' ';
         end loop;
         return VAULT_OK;
      end if;
      return VAULT_ERR;
   exception
      when others => return VAULT_ERR;
   end Mnemonic_Generate_24;

   function Mnemonic_Validate (Mnemonic : chars_ptr) return int is
   begin
      if Mnemonic = Null_Ptr then
         return 0;
      end if;
      return (if SPARK_Mnemonic.Validate (Value (Mnemonic)) then 1 else 0);
   exception
      when others => return 0;
   end Mnemonic_Validate;

   function Mnemonic_To_Seed
      (Mnemonic   : chars_ptr;
       Passphrase : chars_ptr;
       Seed_Buf   : chars_ptr;
       Seed_Cap   : int) return int
   is
      Seed : SPARK_Mnemonic.Seed_Bytes;
      OK   : Boolean;
      Pass : constant String :=
         (if Passphrase = Null_Ptr then "" else Value (Passphrase));
   begin
      if Mnemonic = Null_Ptr or else Seed_Buf = Null_Ptr or else Seed_Cap < 64 then
         return VAULT_ERR;
      end if;

      SPARK_Mnemonic.To_Seed (Value (Mnemonic), Pass, Seed, OK);

      if OK then
         for I in 1 .. 64 loop
            Interfaces.C.Strings.Update
               (Seed_Buf, Interfaces.C.size_t (I - 1),
                Character'Val (Natural (Seed (I))) & "");
         end loop;
         -- Wipe seed from stack
         for I in Seed'Range loop
            Seed (I) := 0;
         end loop;
         return VAULT_OK;
      end if;
      return VAULT_ERR;
   exception
      when others => return VAULT_ERR;
   end Mnemonic_To_Seed;

   -- ── BIP-32 HD Key Derivation ────────────────────────────────

   procedure Copy_Bytes_To_C (Src : Byte_Array; Dst : chars_ptr) is
      use Interfaces.C;
   begin
      C_Memcpy (To_Address (Dst), Src'Address, size_t (Src'Length));
   end Copy_Bytes_To_C;

   function Read_Bytes_From_C (Src : chars_ptr; Len : Natural) return Byte_Array is
      Result : Byte_Array (1 .. Len);
      S : constant String := Value (Src, Interfaces.C.size_t (Len));
   begin
      for I in 1 .. Len loop
         Result (I) := Byte (Character'Pos (S (I)));
      end loop;
      return Result;
   end Read_Bytes_From_C;

   function Bip32_Master_From_Seed
      (Seed_Buf    : chars_ptr;
       Seed_Len    : int;
       Privkey_Buf : chars_ptr;
       Chain_Buf   : chars_ptr) return int
   is
      SL : constant Natural := Natural (Seed_Len);
      Seed : Byte_Array (1 .. SL);
      Master : SPARK_BIP32.Extended_Key;
      S_Str : constant String := Value (Seed_Buf, Interfaces.C.size_t (SL));
   begin
      if Privkey_Buf = Null_Ptr or else Chain_Buf = Null_Ptr then
         return VAULT_ERR;
      end if;

      for I in 1 .. SL loop
         Seed (I) := Byte (Character'Pos (S_Str (I)));
      end loop;

      SPARK_BIP32.Master_Key_From_Seed (Seed, Master);

      if Master.Valid then
         Copy_Bytes_To_C (Byte_Array (Master.Private_Key), Privkey_Buf);
         Copy_Bytes_To_C (Byte_Array (Master.Chain_Code), Chain_Buf);
         SPARK_BIP32.Wipe_Key (Master);
         return VAULT_OK;
      end if;
      return VAULT_ERR;
   exception
      when others => return VAULT_ERR;
   end Bip32_Master_From_Seed;

   function Bip32_Derive_Address
      (Privkey_In  : chars_ptr;
       Chain_In    : chars_ptr;
       Addr_Index  : int;
       Privkey_Out : chars_ptr;
       Chain_Out   : chars_ptr) return int
   is
      Master : SPARK_BIP32.Extended_Key;
      Addr   : SPARK_BIP32.Extended_Key;
      PK     : constant Byte_Array := Read_Bytes_From_C (Privkey_In, 32);
      CC     : constant Byte_Array := Read_Bytes_From_C (Chain_In, 32);
   begin
      if Privkey_Out = Null_Ptr or else Chain_Out = Null_Ptr then
         return VAULT_ERR;
      end if;

      Master.Private_Key := SPARK_BIP32.Key_Bytes (PK);
      Master.Chain_Code  := SPARK_BIP32.Chain_Bytes (CC);
      Master.Valid := True;

      SPARK_BIP32.Derive_Address_Key (Master, Natural (Addr_Index), Addr);

      if Addr.Valid then
         Copy_Bytes_To_C (Byte_Array (Addr.Private_Key), Privkey_Out);
         Copy_Bytes_To_C (Byte_Array (Addr.Chain_Code), Chain_Out);
         SPARK_BIP32.Wipe_Key (Addr);
         SPARK_BIP32.Wipe_Key (Master);
         return VAULT_OK;
      end if;
      SPARK_BIP32.Wipe_Key (Master);
      return VAULT_ERR;
   exception
      when others => return VAULT_ERR;
   end Bip32_Derive_Address;

   function Hmac_Sha512
      (Key_Buf  : chars_ptr;
       Key_Len  : int;
       Msg_Buf  : chars_ptr;
       Msg_Len  : int;
       Out_Buf  : chars_ptr;
       Out_Cap  : int) return int
   is
      KL : constant Natural := Natural (Key_Len);
      ML : constant Natural := Natural (Msg_Len);
      K_Bytes : constant Byte_Array := Read_Bytes_From_C (Key_Buf, KL);
      M_Bytes : constant Byte_Array := Read_Bytes_From_C (Msg_Buf, ML);
      H : SPARK_SHA512.Hash512_Bytes;
   begin
      if Out_Buf = Null_Ptr or else Out_Cap < 64 then
         return VAULT_ERR;
      end if;

      H := SPARK_SHA512.HMAC_SHA512 (K_Bytes, M_Bytes);
      Copy_Bytes_To_C (Byte_Array (H), Out_Buf);
      return VAULT_OK;
   exception
      when others => return VAULT_ERR;
   end Hmac_Sha512;

   -- ── secp256k1 + Address ─────────────────────────────────────

   function Secp256k1_Pubkey
      (Privkey_Buf : chars_ptr;
       Pubkey_Buf  : chars_ptr;
       Pubkey_Cap  : int) return int
   is
      PK  : constant Byte_Array := Read_Bytes_From_C (Privkey_Buf, 32);
      Pub : SPARK_Secp256k1.Pubkey_Bytes;
      OK  : Boolean;
   begin
      if Pubkey_Buf = Null_Ptr or else Pubkey_Cap < 33 then
         return VAULT_ERR;
      end if;
      SPARK_Secp256k1.Pubkey_From_Privkey
         (SPARK_Secp256k1.Privkey_Bytes (PK), Pub, OK);
      if OK then
         Copy_Bytes_To_C (Byte_Array (Pub), Pubkey_Buf);
         return VAULT_OK;
      end if;
      return VAULT_ERR;
   exception
      when others => return VAULT_ERR;
   end Secp256k1_Pubkey;

   function Secp256k1_Sign
      (Privkey_Buf : chars_ptr;
       Hash_Buf    : chars_ptr;
       Sig_Buf     : chars_ptr;
       Sig_Cap     : int) return int
   is
      PK   : constant Byte_Array := Read_Bytes_From_C (Privkey_Buf, 32);
      H    : constant Byte_Array := Read_Bytes_From_C (Hash_Buf, 32);
      Sig  : SPARK_Secp256k1.Signature_Bytes;
      OK   : Boolean;
   begin
      if Sig_Buf = Null_Ptr or else Sig_Cap < 64 then
         return VAULT_ERR;
      end if;
      SPARK_Secp256k1.Sign
         (SPARK_Secp256k1.Privkey_Bytes (PK),
          Hash_Bytes (H), Sig, OK);
      if OK then
         Copy_Bytes_To_C (Byte_Array (Sig), Sig_Buf);
         return VAULT_OK;
      end if;
      return VAULT_ERR;
   exception
      when others => return VAULT_ERR;
   end Secp256k1_Sign;

   function Secp256k1_Verify
      (Pubkey_Buf : chars_ptr;
       Hash_Buf   : chars_ptr;
       Sig_Buf    : chars_ptr) return int
   is
      Pub : constant Byte_Array := Read_Bytes_From_C (Pubkey_Buf, 33);
      H   : constant Byte_Array := Read_Bytes_From_C (Hash_Buf, 32);
      Sig : constant Byte_Array := Read_Bytes_From_C (Sig_Buf, 64);
   begin
      return (if SPARK_Secp256k1.Verify
                    (SPARK_Secp256k1.Pubkey_Bytes (Pub),
                     Hash_Bytes (H),
                     SPARK_Secp256k1.Signature_Bytes (Sig))
              then 1 else 0);
   exception
      when others => return 0;
   end Secp256k1_Verify;

   function Privkey_To_Address
      (Privkey_Buf : chars_ptr;
       Addr_Buf    : chars_ptr;
       Addr_Cap    : int) return int
   is
      PK : constant Byte_Array := Read_Bytes_From_C (Privkey_Buf, 32);
      AR : SPARK_Secp256k1.Address_Result;
   begin
      if Addr_Buf = Null_Ptr or else Addr_Cap < 42 then
         return VAULT_ERR;
      end if;
      SPARK_Secp256k1.Privkey_To_Address
         (SPARK_Secp256k1.Privkey_Bytes (PK), AR);
      if AR.Success then
         Copy_To_C (AR.Data (1 .. AR.Len), Addr_Buf, Addr_Cap);
         return VAULT_OK;
      end if;
      return VAULT_ERR;
   exception
      when others => return VAULT_ERR;
   end Privkey_To_Address;

   -- ── Transaction Engine ────────────────────────────────────

   function TX_Can_Afford
      (Balance : int;
       Amount  : int;
       Fee     : int) return int
   is
   begin
      return (if SPARK_Transaction.Can_Afford
                    (Natural (Balance), Natural (Amount), Natural (Fee))
              then 1 else 0);
   exception
      when others => return 0;
   end TX_Can_Afford;

   function TX_Build_And_Sign
      (Privkey_Buf : chars_ptr;
       To_Address  : chars_ptr;
       Amount_Sat  : int;
       Fee_Sat     : int;
       TX_Out      : chars_ptr;
       TX_Cap      : int;
       TX_Len_Out  : access int;
       TXID_Out    : chars_ptr;
       TXID_Cap    : int) return int
   is
      PK   : SPARK_Secp256k1.Privkey_Bytes;
      PK_B : constant Byte_Array := Read_Bytes_From_C (Privkey_Buf, 32);
      Addr : constant String := Value (To_Address);
      R    : SPARK_Transaction.TX_Result;
   begin
      if TX_Out = Null_Ptr or else TXID_Out = Null_Ptr then
         return VAULT_ERR;
      end if;

      PK := SPARK_Secp256k1.Privkey_Bytes (PK_B);

      SPARK_Transaction.Build_And_Sign
         (PK, Addr, Natural (Amount_Sat), Natural (Fee_Sat), R);

      if R.Success then
         -- Copy TX bytes
         Copy_Bytes_To_C (R.Data (1 .. R.Len), TX_Out);
         TX_Len_Out.all := int (R.Len);
         -- Copy TXID
         Copy_Bytes_To_C (Byte_Array (R.TXID), TXID_Out);
         return VAULT_OK;
      end if;
      return VAULT_ERR;
   exception
      when others => return VAULT_ERR;
   end TX_Build_And_Sign;

   function TX_Compute_TXID
      (TX_Buf   : chars_ptr;
       TX_Len   : int;
       TXID_Buf : chars_ptr;
       TXID_Cap : int) return int
   is
      TL : constant Natural := Natural (TX_Len);
      TX : constant Byte_Array := Read_Bytes_From_C (TX_Buf, TL);
      H  : Hash_Bytes;
   begin
      if TXID_Buf = Null_Ptr or else TXID_Cap < 32 then
         return VAULT_ERR;
      end if;
      H := SPARK_Transaction.Compute_TXID (TX);
      Copy_Bytes_To_C (Byte_Array (H), TXID_Buf);
      return VAULT_OK;
   exception
      when others => return VAULT_ERR;
   end TX_Compute_TXID;

   -- ── SHA-256 ───────────────────────────────────────────────

   function Sha256_Hash
      (Data     : chars_ptr;
       Data_Len : int;
       Out_Buf  : chars_ptr;
       Out_Cap  : int) return int
   is
      DL : constant Natural := Natural (Data_Len);
      H  : Hash_Bytes;
   begin
      if Out_Buf = Null_Ptr or else Out_Cap < 32 then
         return VAULT_ERR;
      end if;

      if DL = 0 then
         -- SHA256 of empty input
         declare
            Empty : constant Byte_Array (1 .. 0) := [others => 0];
         begin
            H := Hash (Empty);
         end;
      else
         declare
            D_Bytes : Byte_Array (1 .. DL);
         begin
            -- Read raw bytes from C pointer
            C_Memcpy (D_Bytes'Address, To_Address (Data),
                      Interfaces.C.size_t (DL));
            H := Hash (D_Bytes);
         end;
      end if;

      -- Write 32 hash bytes to output
      C_Memcpy (To_Address (Out_Buf), H'Address, 32);
      return VAULT_OK;
   exception
      when others => return VAULT_ERR;
   end Sha256_Hash;

   function Sha256_Double
      (Data     : chars_ptr;
       Data_Len : int;
       Out_Buf  : chars_ptr;
       Out_Cap  : int) return int
   is
      DL : constant Natural := Natural (Data_Len);
      H  : Hash_Bytes;
   begin
      if Out_Buf = Null_Ptr or else Out_Cap < 32 then
         return VAULT_ERR;
      end if;

      if DL = 0 then
         declare
            Empty : constant Byte_Array (1 .. 0) := [others => 0];
         begin
            H := Hash256 (Empty);
         end;
      else
         declare
            D_Bytes : Byte_Array (1 .. DL);
         begin
            C_Memcpy (D_Bytes'Address, To_Address (Data),
                      Interfaces.C.size_t (DL));
            H := Hash256 (D_Bytes);
         end;
      end if;

      C_Memcpy (To_Address (Out_Buf), H'Address, 32);
      return VAULT_OK;
   exception
      when others => return VAULT_ERR;
   end Sha256_Double;

end Vault_C_API;

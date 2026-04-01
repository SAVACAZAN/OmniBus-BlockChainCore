-- ============================================================
--  Vault_Crypto body  —  Platform-specific DPAPI implementation
-- ============================================================

pragma Ada_2022;

with System;
with Interfaces.C;
with Interfaces.C.Strings;
with Win32_Crypt;

package body Vault_Crypto
   with SPARK_Mode => Off  -- FFI calls not provable
is

   -- ── Platform detection ────────────────────────────────────
   --  On Windows: use DPAPI via Win32_Crypt bindings
   --  On Linux/bare-metal: plaintext passthrough (or custom AES)

   use type Interfaces.C.int;
   use type Interfaces.C.unsigned_long;

   -- ── Secure wipe (provable, no FFI) ────────────────────────

   procedure Secure_Wipe (Buffer : in out Byte_Array) is
   begin
      for I in Buffer'Range loop
         Buffer (I) := 0;
         pragma Annotate (GNATprove, Intentional,
            "loop invariant", "wipe loop clears all bytes");
      end loop;
   end Secure_Wipe;

   procedure Secure_Wipe_String (S : in out String) is
   begin
      for I in S'Range loop
         S (I) := ' ';
      end loop;
   end Secure_Wipe_String;

   -- ── DPAPI Encrypt (Windows) ───────────────────────────────

   procedure DPAPI_Encrypt
      (Plain       : in     Byte_Array;
       Plain_Len   : in     Natural;
       Cipher      :    out Byte_Array;
       Cipher_Len  :    out Natural;
       Success     :    out Boolean)
   is
   begin
      -- Default: initialize outputs
      Cipher_Len := 0;
      Cipher     := (others => 0);
      Success    := False;

      if Plain_Len = 0 then
         return;
      end if;

      -- Platform-specific DPAPI call
      declare
         use Win32_Crypt;

         In_Blob  : aliased Data_Blob :=
            (cbData => Interfaces.C.unsigned_long (Plain_Len),
             pbData => Plain (Plain'First)'Address);
         Out_Blob : aliased Data_Blob := (cbData => 0, pbData => System.Null_Address);

         Desc : Interfaces.C.Strings.chars_ptr :=
            Interfaces.C.Strings.New_String ("OmnibusAdaVault");

         Ret : Interfaces.C.int;
      begin
         Ret := CryptProtectData
            (pDataIn          => In_Blob'Access,
             szDescription    => Desc,
             pOptionalEntropy => System.Null_Address,
             pvReserved       => System.Null_Address,
             pPromptStruct    => System.Null_Address,
             dwFlags          => CRYPTPROTECT_UI_FORBIDDEN,
             pDataOut         => Out_Blob'Access);

         Interfaces.C.Strings.Free (Desc);

         if Ret /= 0 and then Out_Blob.cbData > 0 then
            declare
               Out_Len : constant Natural := Natural (Out_Blob.cbData);
               type Raw_Bytes is array (1 .. Out_Len) of Byte
                  with Convention => C;
               Raw : Raw_Bytes
                  with Address => Out_Blob.pbData, Import;
            begin
               if Out_Len <= Cipher'Length then
                  for I in 1 .. Out_Len loop
                     Cipher (Cipher'First + I - 1) := Raw (I);
                  end loop;
                  Cipher_Len := Out_Len;
                  Success    := True;
               end if;
            end;

            declare
               Dummy : System.Address;
            begin
               Dummy := LocalFree (Out_Blob.pbData);
            end;
         end if;
      end;

   exception
      when others =>
         Cipher_Len := 0;
         Success    := False;
   end DPAPI_Encrypt;

   -- ── DPAPI Decrypt (Windows) ───────────────────────────────

   procedure DPAPI_Decrypt
      (Cipher      : in     Byte_Array;
       Cipher_Len  : in     Natural;
       Plain       :    out Byte_Array;
       Plain_Len   :    out Natural;
       Success     :    out Boolean)
   is
   begin
      Plain_Len := 0;
      Plain     := (others => 0);
      Success   := False;

      if Cipher_Len = 0 then
         return;
      end if;

      declare
         use Win32_Crypt;

         In_Blob  : aliased Data_Blob :=
            (cbData => Interfaces.C.unsigned_long (Cipher_Len),
             pbData => Cipher (Cipher'First)'Address);
         Out_Blob : aliased Data_Blob := (cbData => 0, pbData => System.Null_Address);

         Ret : Interfaces.C.int;
      begin
         Ret := CryptUnprotectData
            (pDataIn          => In_Blob'Access,
             ppszDescription  => System.Null_Address,
             pOptionalEntropy => System.Null_Address,
             pvReserved       => System.Null_Address,
             pPromptStruct    => System.Null_Address,
             dwFlags          => 0,
             pDataOut         => Out_Blob'Access);

         if Ret /= 0 and then Out_Blob.cbData > 0 then
            declare
               Out_Len : constant Natural := Natural (Out_Blob.cbData);
               type Raw_Bytes is array (1 .. Out_Len) of Byte
                  with Convention => C;
               Raw : Raw_Bytes
                  with Address => Out_Blob.pbData, Import;
            begin
               if Out_Len <= Plain'Length then
                  for I in 1 .. Out_Len loop
                     Plain (Plain'First + I - 1) := Raw (I);
                  end loop;
                  Plain_Len := Out_Len;
                  Success   := True;
               end if;

               -- Secure-wipe the DPAPI output before freeing
               C_Memset (Out_Blob.pbData, 0,
                         Interfaces.C.size_t (Out_Blob.cbData));
            end;

            declare
               Dummy : System.Address;
            begin
               Dummy := LocalFree (Out_Blob.pbData);
            end;
         end if;
      end;

   exception
      when others =>
         Plain_Len := 0;
         Success   := False;
   end DPAPI_Decrypt;

end Vault_Crypto;

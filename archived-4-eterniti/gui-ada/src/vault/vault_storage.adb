-- ============================================================
--  Vault_Storage body  —  Serialize/deserialize + DPAPI I/O
--
--  File format v4 (same as SuperVault):
--  [MAGIC:4][VERSION:4][EXCH_COUNT:4]
--  per exchange:
--    [SLOT_COUNT:4]
--    per slot:
--      [IN_USE:1][STATUS:1]
--      [name_len:4][name_utf8]
--      [key_len:4][key_utf8]
--      [secret_len:4][secret_utf8]
--
--  Entire payload DPAPI-encrypted before disk write.
-- ============================================================

pragma Ada_2022;

with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Streams.Stream_IO;
with Vault_Crypto;

package body Vault_Storage
   with SPARK_Mode => Off  -- I/O and DPAPI not provable
is

   -- ── Internal state ────────────────────────────────────────

   Stores   : Exchange_Store := (others => (others => Empty_Key_Entry));
   Loaded   : Boolean := False;

   -- ── State query ───────────────────────────────────────────

   function Is_Loaded return Boolean is (Loaded);

   -- ── Vault file path ──────────────────────────────────────

   function Vault_File_Path return String is
      App_Data : constant String :=
         Ada.Environment_Variables.Value ("APPDATA", ".");
   begin
      return App_Data & "\OmniBus-Ada\exchange-keys.vault";
   end Vault_File_Path;

   -- ── Ensure directory exists ───────────────────────────────

   procedure Ensure_Dir (Path : String) is
      -- Find last backslash
      Last_Sep : Natural := 0;
   begin
      for I in reverse Path'Range loop
         if Path (I) = '\' or else Path (I) = '/' then
            Last_Sep := I;
            exit;
         end if;
      end loop;

      if Last_Sep > Path'First then
         declare
            Dir : constant String := Path (Path'First .. Last_Sep - 1);
         begin
            if not Ada.Directories.Exists (Dir) then
               Ada.Directories.Create_Path (Dir);
            end if;
         end;
      end if;
   end Ensure_Dir;

   -- ── Serialization helpers ─────────────────────────────────

   use Vault_Crypto;

   procedure Write_U32
      (Buf : in out Byte_Array; Pos : in out Natural; Val : Natural)
   is
      V : Natural := Val;
   begin
      Buf (Pos + 1) := Byte (V mod 256); V := V / 256;
      Buf (Pos + 2) := Byte (V mod 256); V := V / 256;
      Buf (Pos + 3) := Byte (V mod 256); V := V / 256;
      Buf (Pos + 4) := Byte (V mod 256);
      Pos := Pos + 4;
   end Write_U32;

   function Read_U32 (Buf : Byte_Array; Pos : Natural) return Natural is
   begin
      return Natural (Buf (Pos + 1))
           + Natural (Buf (Pos + 2)) * 256
           + Natural (Buf (Pos + 3)) * 65_536
           + Natural (Buf (Pos + 4)) * 16_777_216;
   end Read_U32;

   procedure Write_U8
      (Buf : in out Byte_Array; Pos : in out Natural; Val : Natural)
   is
   begin
      Buf (Pos + 1) := Byte (Val mod 256);
      Pos := Pos + 1;
   end Write_U8;

   procedure Write_Str
      (Buf : in out Byte_Array; Pos : in out Natural;
       S : String; Len : Natural)
   is
   begin
      Write_U32 (Buf, Pos, Len);
      for I in 1 .. Len loop
         Buf (Pos + I) := Byte (Character'Pos (S (I)));
      end loop;
      Pos := Pos + Len;
   end Write_Str;

   function Read_Str
      (Buf : Byte_Array; Pos : in out Natural;
       Max_Len : Natural) return String
   is
      Len : constant Natural := Natural'Min (Read_U32 (Buf, Pos), Max_Len);
      Result : String (1 .. Len);
   begin
      Pos := Pos + 4;
      for I in 1 .. Len loop
         Result (I) := Character'Val (Natural (Buf (Pos + I)));
      end loop;
      Pos := Pos + Len;
      return Result;
   end Read_Str;

   -- ── Serialize ─────────────────────────────────────────────

   procedure Serialize
      (Buf : out Byte_Array; Len : out Natural)
   is
      Pos : Natural := 0;
   begin
      Buf := (others => 0);
      Len := 0;

      Write_U32 (Buf, Pos, Vault_Magic);
      Write_U32 (Buf, Pos, Vault_Version);
      Write_U32 (Buf, Pos, Exchange_Count);

      for Ex in Exchange_Id loop
         Write_U32 (Buf, Pos, Max_Keys_Per_Exchange);

         for S in Slot_Index loop
            declare
               E : Key_Entry renames Stores (Ex)(S);
            begin
               Write_U8 (Buf, Pos, (if E.In_Use then 1 else 0));
               Write_U8 (Buf, Pos, Key_Status'Pos (E.Status));
               Write_Str (Buf, Pos, E.Name.Data, E.Name.Len);
               Write_Str (Buf, Pos, E.Api_Key.Data, E.Api_Key.Len);
               Write_Str (Buf, Pos, E.Api_Secret.Data, E.Api_Secret.Len);
            end;
         end loop;
      end loop;

      Len := Pos;
   end Serialize;

   -- ── Deserialize ───────────────────────────────────────────

   procedure Deserialize
      (Buf : Byte_Array; Len : Natural; Success : out Boolean)
   is
      Pos   : Natural := 0;
      Magic : Natural;
      Ver   : Natural;
      ExCnt : Natural;
   begin
      Success := False;

      if Len < 12 then
         return;
      end if;

      Magic := Read_U32 (Buf, Pos); Pos := Pos + 4;
      Ver   := Read_U32 (Buf, Pos); Pos := Pos + 4;
      ExCnt := Read_U32 (Buf, Pos); Pos := Pos + 4;

      if Magic /= Vault_Magic or else Ver /= Vault_Version then
         return;
      end if;

      for Ex in Exchange_Id loop
         exit when Exchange_Id'Pos (Ex) >= ExCnt;

         declare
            Slot_Cnt : constant Natural :=
               Natural'Min (Read_U32 (Buf, Pos), Max_Keys_Per_Exchange);
         begin
            Pos := Pos + 4;

            for S in 0 .. Slot_Cnt - 1 loop
               if S <= Natural (Slot_Index'Last) then
                  declare
                     SI      : constant Slot_Index := Slot_Index (S);
                     In_Use  : constant Natural :=
                        Natural (Buf (Pos + 1));
                     St_Val  : Natural;
                     N_Str   : String (1 .. Max_Name_Length);
                     N_Len   : Natural;
                     K_Str   : String (1 .. Max_Key_Length);
                     K_Len   : Natural;
                     Sec_Str : String (1 .. Max_Secret_Length);
                     Sec_Len : Natural;
                  begin
                     Pos := Pos + 1;
                     St_Val := Natural (Buf (Pos + 1));
                     Pos := Pos + 1;

                     -- Read name
                     N_Len := Natural'Min (Read_U32 (Buf, Pos),
                                           Max_Name_Length);
                     Pos := Pos + 4;
                     N_Str := (others => ' ');
                     for I in 1 .. N_Len loop
                        N_Str (I) := Character'Val (Natural (Buf (Pos + I)));
                     end loop;
                     Pos := Pos + N_Len;

                     -- Read api_key
                     K_Len := Natural'Min (Read_U32 (Buf, Pos),
                                           Max_Key_Length);
                     Pos := Pos + 4;
                     K_Str := (others => ' ');
                     for I in 1 .. K_Len loop
                        K_Str (I) := Character'Val (Natural (Buf (Pos + I)));
                     end loop;
                     Pos := Pos + K_Len;

                     -- Read api_secret
                     Sec_Len := Natural'Min (Read_U32 (Buf, Pos),
                                             Max_Secret_Length);
                     Pos := Pos + 4;
                     Sec_Str := (others => ' ');
                     for I in 1 .. Sec_Len loop
                        Sec_Str (I) :=
                           Character'Val (Natural (Buf (Pos + I)));
                     end loop;
                     Pos := Pos + Sec_Len;

                     Stores (Ex)(SI) :=
                        (In_Use     => In_Use /= 0,
                         Status     =>
                           (if St_Val <= Key_Status'Pos (Key_Status'Last)
                            then Key_Status'Val (St_Val)
                            else Status_Free),
                         Name       => (Data => N_Str, Len => N_Len),
                         Api_Key    => (Data => K_Str, Len => K_Len),
                         Api_Secret => (Data => Sec_Str, Len => Sec_Len));
                  end;
               end if;
            end loop;
         end;
      end loop;

      Success := True;
   end Deserialize;

   -- ── Init ──────────────────────────────────────────────────

   procedure Init (Success : out Boolean) is
      Path : constant String := Vault_File_Path;
      use Ada.Streams.Stream_IO;
   begin
      Stores  := (others => (others => Empty_Key_Entry));
      Success := False;

      if not Ada.Directories.Exists (Path) then
         -- No file yet — empty vault is valid
         Loaded  := True;
         Success := True;
         return;
      end if;

      -- Read encrypted file
      declare
         F    : File_Type;
         Size : constant Natural :=
            Natural (Ada.Directories.Size (Path));
         Cipher : Byte_Array (1 .. Size);
         Plain  : Byte_Array (1 .. Max_Vault_Buffer);
         P_Len  : Natural;
         D_OK   : Boolean;
         Last   : Ada.Streams.Stream_Element_Offset;
      begin
         Open (F, In_File, Path);
         declare
            S : Stream_Access := Stream (F);
            Raw : Ada.Streams.Stream_Element_Array (1 ..
               Ada.Streams.Stream_Element_Offset (Size));
         begin
            Ada.Streams.Read (S.all, Raw, Last);
            for I in Raw'Range loop
               Cipher (Positive (I)) := Raw (I);
            end loop;
         end;
         Close (F);

         DPAPI_Decrypt (Cipher, Size, Plain, P_Len, D_OK);

         if D_OK then
            Deserialize (Plain, P_Len, Success);
            Secure_Wipe (Plain);
         end if;
      end;

      Loaded := Success;

   exception
      when others =>
         Loaded  := True;   -- start fresh on error
         Success := True;
   end Init;

   -- ── Save ──────────────────────────────────────────────────

   procedure Save (Success : out Boolean) is
      Path  : constant String := Vault_File_Path;
      Plain : Byte_Array (1 .. Max_Vault_Buffer);
      P_Len : Natural;
      Cipher : Byte_Array (1 .. Max_Vault_Buffer);
      C_Len  : Natural;
      use Ada.Streams.Stream_IO;
   begin
      Success := False;
      Ensure_Dir (Path);

      Serialize (Plain, P_Len);

      if P_Len = 0 then
         Success := True;
         return;
      end if;

      DPAPI_Encrypt (Plain, P_Len, Cipher, C_Len, Success);
      Secure_Wipe (Plain);

      if not Success then
         return;
      end if;

      declare
         F : File_Type;
      begin
         Create (F, Out_File, Path);
         declare
            S : Stream_Access := Stream (F);
            Raw : Ada.Streams.Stream_Element_Array (1 ..
               Ada.Streams.Stream_Element_Offset (C_Len));
         begin
            for I in Raw'Range loop
               Raw (I) := Cipher (Positive (I));
            end loop;
            Ada.Streams.Write (S.all, Raw);
         end;
         Close (F);
         Success := True;
      exception
         when others =>
            Success := False;
      end;
   end Save;

   -- ── Lock ──────────────────────────────────────────────────

   procedure Lock is
   begin
      for Ex in Exchange_Id loop
         for S in Slot_Index loop
            declare
               E : Key_Entry renames Stores (Ex)(S);
            begin
               Secure_Wipe_String (E.Name.Data);
               Secure_Wipe_String (E.Api_Key.Data);
               Secure_Wipe_String (E.Api_Secret.Data);
               E := Empty_Key_Entry;
            end;
         end loop;
      end loop;
      Loaded := False;
   end Lock;

   -- ── Add_Key ───────────────────────────────────────────────

   procedure Add_Key
      (Ex      : Exchange_Id;
       Name    : Name_String;
       Api_Key : Key_String;
       Secret  : Secret_String;
       Status  : Key_Status;
       Success : out Boolean)
   is
   begin
      Success := False;
      for S in Slot_Index loop
         if not Stores (Ex)(S).In_Use then
            Stores (Ex)(S) :=
               (In_Use     => True,
                Status     => Status,
                Name       => Name,
                Api_Key    => Api_Key,
                Api_Secret => Secret);
            Save (Success);
            return;
         end if;
      end loop;
      -- All slots full
   end Add_Key;

   -- ── Delete_Key ────────────────────────────────────────────

   procedure Delete_Key
      (Ex      : Exchange_Id;
       Slot    : Slot_Index;
       Success : out Boolean)
   is
   begin
      declare
         E : Key_Entry renames Stores (Ex)(Slot);
      begin
         Secure_Wipe_String (E.Name.Data);
         Secure_Wipe_String (E.Api_Key.Data);
         Secure_Wipe_String (E.Api_Secret.Data);
         E := Empty_Key_Entry;
      end;
      Save (Success);
   end Delete_Key;

   -- ── Update_Key ────────────────────────────────────────────

   procedure Update_Key
      (Ex      : Exchange_Id;
       Slot    : Slot_Index;
       Name    : Name_String;
       Api_Key : Key_String;
       Secret  : Secret_String;
       Status  : Key_Status;
       Success : out Boolean)
   is
   begin
      Stores (Ex)(Slot) :=
         (In_Use     => True,
          Status     => Status,
          Name       => Name,
          Api_Key    => Api_Key,
          Api_Secret => Secret);
      Save (Success);
   end Update_Key;

   -- ── Get_Key ───────────────────────────────────────────────

   function Get_Key
      (Ex   : Exchange_Id;
       Slot : Slot_Index) return Key_Entry
   is
   begin
      return Stores (Ex)(Slot);
   end Get_Key;

   -- ── Key_Count ─────────────────────────────────────────────

   function Key_Count (Ex : Exchange_Id) return Natural is
      N : Natural := 0;
   begin
      for S in Slot_Index loop
         if Stores (Ex)(S).In_Use then
            N := N + 1;
         end if;
      end loop;
      return N;
   end Key_Count;

   -- ── Has_Keys ──────────────────────────────────────────────

   function Has_Keys (Ex : Exchange_Id) return Boolean is
   begin
      for S in Slot_Index loop
         if Stores (Ex)(S).In_Use then
            return True;
         end if;
      end loop;
      return False;
   end Has_Keys;

   -- ── Set_Key_Status ────────────────────────────────────────

   procedure Set_Key_Status
      (Ex      : Exchange_Id;
       Slot    : Slot_Index;
       Status  : Key_Status;
       Success : out Boolean)
   is
   begin
      if not Stores (Ex)(Slot).In_Use then
         Success := False;
         return;
      end if;
      Stores (Ex)(Slot).Status := Status;
      Save (Success);
   end Set_Key_Status;

end Vault_Storage;

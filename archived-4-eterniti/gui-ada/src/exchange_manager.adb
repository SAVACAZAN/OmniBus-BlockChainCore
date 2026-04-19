-- ============================================================
--  Exchange_Manager body  —  Vault facade + JSON serialization
-- ============================================================

pragma Ada_2022;

with Vault_Storage;

package body Exchange_Manager
   with SPARK_Mode => Off  -- String concatenation not provable
is

   -- ── Helpers ───────────────────────────────────────────────

   procedure Append
      (Buf : in out JSON_String; Pos : in out Natural; S : String)
   is
   begin
      for I in S'Range loop
         if Pos < Max_JSON_Length then
            Pos := Pos + 1;
            Buf (Pos) := S (I);
         end if;
      end loop;
   end Append;

   function Mask_Key (S : String; Len : Natural) return String is
   begin
      if Len <= 12 then
         return S (1 .. Len);
      else
         return S (1 .. 6) & "***" & S (Len - 3 .. Len);
      end if;
   end Mask_Key;

   function Img (N : Natural) return String is
      S : constant String := Natural'Image (N);
   begin
      -- Strip leading space
      if S'Length > 0 and then S (S'First) = ' ' then
         return S (S'First + 1 .. S'Last);
      end if;
      return S;
   end Img;

   -- Escape JSON string (minimal: quotes and backslashes)
   function Escape (S : String) return String is
      Result : String (1 .. S'Length * 2);
      Pos    : Natural := 0;
   begin
      for I in S'Range loop
         if S (I) = '"' then
            Pos := Pos + 1; Result (Pos) := '\';
            Pos := Pos + 1; Result (Pos) := '"';
         elsif S (I) = '\' then
            Pos := Pos + 1; Result (Pos) := '\';
            Pos := Pos + 1; Result (Pos) := '\';
         else
            Pos := Pos + 1; Result (Pos) := S (I);
         end if;
      end loop;
      return Result (1 .. Pos);
   end Escape;

   -- ── Init ──────────────────────────────────────────────────

   procedure Init (Success : out Boolean) is
   begin
      -- Try service mode first, fallback to embedded
      Vault_Pipe_Client.Init (Mode_Service, Success);
   end Init;

   -- ── List_Keys_JSON ────────────────────────────────────────

   procedure List_Keys_JSON
      (Ex   : Exchange_Id;
       JSON : out JSON_String;
       Len  : out Natural)
   is
      Pos   : Natural := 0;
      First : Boolean := True;
   begin
      JSON := (others => ' ');
      Len  := 0;

      Append (JSON, Pos, "{""exchange"":""" & Exchange_Name (Ex) & """,");
      Append (JSON, Pos, """keys"":[");

      if Vault_Storage.Is_Loaded then
         for S in Slot_Index loop
            declare
               E : constant Key_Entry := Vault_Storage.Get_Key (Ex, S);
            begin
               if E.In_Use then
                  if not First then
                     Append (JSON, Pos, ",");
                  end if;
                  First := False;

                  Append (JSON, Pos, "{""slot"":" & Img (Natural (S)));
                  Append (JSON, Pos, ",""name"":"""
                     & Escape (E.Name.Data (1 .. E.Name.Len)) & """");
                  Append (JSON, Pos, ",""apiKey"":"""
                     & Mask_Key (E.Api_Key.Data, E.Api_Key.Len) & """");
                  Append (JSON, Pos, ",""status"":"""
                     & Status_Name (E.Status) & """");
                  Append (JSON, Pos, "}");
               end if;
            end;
         end loop;
      end if;

      Append (JSON, Pos, "],""count"":" & Img (Vault_Storage.Key_Count (Ex)));
      Append (JSON, Pos, ",""maxKeys"":" & Img (Max_Keys_Per_Exchange));
      Append (JSON, Pos, "}");

      Len := Pos;
   end List_Keys_JSON;

   -- ── Status_JSON ───────────────────────────────────────────

   procedure Status_JSON
      (JSON : out JSON_String;
       Len  : out Natural)
   is
      Pos : Natural := 0;
   begin
      JSON := (others => ' ');
      Len  := 0;

      Append (JSON, Pos, "{""loaded"":");
      Append (JSON, Pos,
         (if Vault_Storage.Is_Loaded then "true" else "false"));
      Append (JSON, Pos, ",""mode"":"""
         & (if Current_Mode = Mode_Service then "service" else "embedded")
         & """");
      Append (JSON, Pos, ",""vaultFile"":"""
         & Escape (Vault_Storage.Vault_File_Path) & """");

      Append (JSON, Pos, ",""exchanges"":{");
      for Ex in Exchange_Id loop
         if Ex /= Exchange_Id'First then
            Append (JSON, Pos, ",");
         end if;
         Append (JSON, Pos, """" & Exchange_Name (Ex) & """:");
         if Vault_Storage.Is_Loaded then
            Append (JSON, Pos, Img (Vault_Storage.Key_Count (Ex)));
         else
            Append (JSON, Pos, "0");
         end if;
      end loop;
      Append (JSON, Pos, "}}");

      Len := Pos;
   end Status_JSON;

   -- ── Handle_Add_Key ────────────────────────────────────────

   procedure Handle_Add_Key
      (Ex       : Exchange_Id;
       Name     : String;
       Api_Key  : String;
       Secret   : String;
       Status   : Key_Status;
       Result   : out Vault_Error)
   is
   begin
      if not Vault_Storage.Is_Loaded then
         Result := Err_Locked;
         return;
      end if;

      declare
         OK : Boolean;
      begin
         Vault_Storage.Add_Key
            (Ex      => Ex,
             Name    => To_Name_String (Name),
             Api_Key => To_Key_String (Api_Key),
             Secret  => To_Secret_String (Secret),
             Status  => Status,
             Success => OK);
         Result := (if OK then Err_OK else Err_Full);
      end;
   end Handle_Add_Key;

   -- ── Handle_Delete_Key ─────────────────────────────────────

   procedure Handle_Delete_Key
      (Ex     : Exchange_Id;
       Slot   : Slot_Index;
       Result : out Vault_Error)
   is
   begin
      if not Vault_Storage.Is_Loaded then
         Result := Err_Locked;
         return;
      end if;

      declare
         OK : Boolean;
      begin
         Vault_Storage.Delete_Key (Ex, Slot, OK);
         Result := (if OK then Err_OK else Err_IO);
      end;
   end Handle_Delete_Key;

   -- ── Handle_Update_Key ─────────────────────────────────────

   procedure Handle_Update_Key
      (Ex      : Exchange_Id;
       Slot    : Slot_Index;
       Name    : String;
       Api_Key : String;
       Secret  : String;
       Status  : Key_Status;
       Result  : out Vault_Error)
   is
   begin
      if not Vault_Storage.Is_Loaded then
         Result := Err_Locked;
         return;
      end if;

      declare
         OK : Boolean;
      begin
         Vault_Storage.Update_Key
            (Ex, Slot,
             To_Name_String (Name),
             To_Key_String (Api_Key),
             To_Secret_String (Secret),
             Status, OK);
         Result := (if OK then Err_OK else Err_IO);
      end;
   end Handle_Update_Key;

   -- ── Handle_Lock ───────────────────────────────────────────

   procedure Handle_Lock (Result : out Vault_Error) is
   begin
      Vault_Storage.Lock;
      Result := Err_OK;
   end Handle_Lock;

   -- ── Handle_Unlock ─────────────────────────────────────────

   procedure Handle_Unlock (Result : out Vault_Error) is
      OK : Boolean;
   begin
      Vault_Storage.Init (OK);
      Result := (if OK then Err_OK else Err_Decrypt);
   end Handle_Unlock;

   -- ── Handle_Set_Status ─────────────────────────────────────

   procedure Handle_Set_Status
      (Ex     : Exchange_Id;
       Slot   : Slot_Index;
       Status : Key_Status;
       Result : out Vault_Error)
   is
   begin
      if not Vault_Storage.Is_Loaded then
         Result := Err_Locked;
         return;
      end if;

      declare
         OK : Boolean;
      begin
         Vault_Storage.Set_Key_Status (Ex, Slot, Status, OK);
         Result := (if OK then Err_OK else Err_Not_Found);
      end;
   end Handle_Set_Status;

end Exchange_Manager;

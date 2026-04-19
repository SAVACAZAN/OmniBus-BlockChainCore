-- ============================================================
--  Vault_Pipe_Client body  —  Named Pipe + Embedded modes
-- ============================================================

pragma Ada_2022;

with Vault_Storage;
with Vault_Crypto;
with Win32_Pipes;
with Interfaces.C;
with Interfaces.C.Strings;

package body Vault_Pipe_Client
   with SPARK_Mode => Off  -- FFI calls
is

   use Interfaces.C;
   use type Interfaces.C.int;

   Active_Mode : Client_Mode := Mode_Embedded;
   Initialized : Boolean := False;

   -- ── Pipe buffer ───────────────────────────────────────────

   Pipe_Buf_Size : constant := 8192;
   type Pipe_Buffer is array (1 .. Pipe_Buf_Size) of Vault_Crypto.Byte;

   -- ── Named Pipe call wrapper ───────────────────────────────

   procedure Call_Pipe
      (Request  : Pipe_Buffer;
       Req_Len  : Natural;
       Response : out Pipe_Buffer;
       Resp_Len : out Natural;
       Success  : out Boolean)
   is
   begin
      Response := (others => 0);
      Resp_Len := 0;
      Success  := False;

      declare
         use Win32_Pipes;
         Pipe : Interfaces.C.Strings.chars_ptr :=
            Interfaces.C.Strings.New_String
               ("\\.\pipe\OmnibusVault");
         Bytes_Read : aliased Interfaces.C.unsigned_long := 0;
         Ret : Interfaces.C.int;
      begin
         Ret := CallNamedPipeA
            (lpNamedPipeName => Pipe,
             lpInBuffer      => Request (1)'Address,
             nInBufferSize   => Interfaces.C.unsigned_long (Req_Len),
             lpOutBuffer     => Response (1)'Address,
             nOutBufferSize  => Pipe_Buf_Size,
             lpBytesRead     => Bytes_Read'Access,
             nTimeOut        => Default_Pipe_Timeout_Ms);

         Interfaces.C.Strings.Free (Pipe);

         if Ret /= 0 then
            Resp_Len := Natural (Bytes_Read);
            Success  := True;
         end if;
      end;
   exception
      when others =>
         Success := False;
   end Call_Pipe;

   -- ── Init ──────────────────────────────────────────────────

   procedure Init
      (Mode    : Client_Mode := Mode_Embedded;
       Success : out Boolean)
   is
   begin
      Active_Mode := Mode;

      case Mode is
         when Mode_Embedded =>
            Vault_Storage.Init (Success);

         when Mode_Service =>
            -- Check if pipe service is reachable
            if Service_Available then
               Success := True;
            else
               -- Fallback to embedded
               Active_Mode := Mode_Embedded;
               Vault_Storage.Init (Success);
            end if;
      end case;

      Initialized := Success;
   end Init;

   -- ── Service_Available ─────────────────────────────────────

   function Service_Available return Boolean is
      Req  : Pipe_Buffer := (others => 0);
      Resp : Pipe_Buffer;
      R_Len : Natural;
      OK   : Boolean;
   begin
      -- Send COUNT for LCX as a ping
      Req (1) := Vault_Crypto.Byte (Vault_Opcode'Pos (Op_Count));
      Req (2) := 0;  -- LCX
      Call_Pipe (Req, 2, Resp, R_Len, OK);
      return OK;
   exception
      when others => return False;
   end Service_Available;

   -- ── Current_Mode ──────────────────────────────────────────

   function Current_Mode return Client_Mode is (Active_Mode);

   -- ── Pipe_Add ──────────────────────────────────────────────

   procedure Pipe_Add
      (Ex       : Exchange_Id;
       Name     : String;
       Api_Key  : String;
       Secret   : String;
       Result   : out Vault_Error)
   is
   begin
      case Active_Mode is
         when Mode_Embedded =>
            declare
               OK : Boolean;
            begin
               Vault_Storage.Add_Key
                  (Ex      => Ex,
                   Name    => To_Name_String (Name),
                   Api_Key => To_Key_String (Api_Key),
                   Secret  => To_Secret_String (Secret),
                   Status  => Status_Free,
                   Success => OK);
               Result := (if OK then Err_OK else Err_Full);
            end;

         when Mode_Service =>
            declare
               Req    : Pipe_Buffer := (others => 0);
               Resp   : Pipe_Buffer;
               R_Len  : Natural;
               Pos    : Natural := 0;
               OK     : Boolean;
            begin
               -- [opcode:1][exchange:1][name_len:2][name][key_len:2][key][secret_len:2][secret]
               Req (1) := Vault_Crypto.Byte (16#41#);  -- Op_Add
               Req (2) := Vault_Crypto.Byte (Exchange_Id'Pos (Ex));
               Pos := 2;

               -- Name (uint16 LE)
               Req (Pos + 1) := Vault_Crypto.Byte (Name'Length mod 256);
               Req (Pos + 2) := Vault_Crypto.Byte (Name'Length / 256);
               Pos := Pos + 2;
               for I in Name'Range loop
                  Pos := Pos + 1;
                  Req (Pos) := Vault_Crypto.Byte (Character'Pos (Name (I)));
               end loop;

               -- API Key (uint16 LE)
               Req (Pos + 1) := Vault_Crypto.Byte (Api_Key'Length mod 256);
               Req (Pos + 2) := Vault_Crypto.Byte (Api_Key'Length / 256);
               Pos := Pos + 2;
               for I in Api_Key'Range loop
                  Pos := Pos + 1;
                  Req (Pos) := Vault_Crypto.Byte (Character'Pos (Api_Key (I)));
               end loop;

               -- Secret (uint16 LE)
               Req (Pos + 1) := Vault_Crypto.Byte (Secret'Length mod 256);
               Req (Pos + 2) := Vault_Crypto.Byte (Secret'Length / 256);
               Pos := Pos + 2;
               for I in Secret'Range loop
                  Pos := Pos + 1;
                  Req (Pos) := Vault_Crypto.Byte (Character'Pos (Secret (I)));
               end loop;

               Call_Pipe (Req, Pos, Resp, R_Len, OK);

               if OK and then R_Len >= 1 then
                  declare
                     Err_Val : constant Natural := Natural (Resp (1));
                  begin
                     if Err_Val <= Vault_Error'Pos (Vault_Error'Last) then
                        Result := Vault_Error'Val (Err_Val);
                     else
                        Result := Err_Invalid;
                     end if;
                  end;
               else
                  Result := Err_No_Service;
               end if;
            end;
      end case;
   end Pipe_Add;

   -- ── Pipe_Delete ───────────────────────────────────────────

   procedure Pipe_Delete
      (Ex     : Exchange_Id;
       Slot   : Slot_Index;
       Result : out Vault_Error)
   is
   begin
      case Active_Mode is
         when Mode_Embedded =>
            declare
               OK : Boolean;
            begin
               Vault_Storage.Delete_Key (Ex, Slot, OK);
               Result := (if OK then Err_OK else Err_IO);
            end;

         when Mode_Service =>
            declare
               Req  : Pipe_Buffer := (others => 0);
               Resp : Pipe_Buffer;
               R_Len : Natural;
               OK   : Boolean;
               S_Val : constant Natural := Natural (Slot);
            begin
               Req (1) := Vault_Crypto.Byte (16#43#);  -- Op_Delete
               Req (2) := Vault_Crypto.Byte (Exchange_Id'Pos (Ex));
               Req (3) := Vault_Crypto.Byte (S_Val mod 256);
               Req (4) := Vault_Crypto.Byte ((S_Val / 256) mod 256);
               Req (5) := Vault_Crypto.Byte ((S_Val / 65536) mod 256);
               Req (6) := Vault_Crypto.Byte (S_Val / 16777216);

               Call_Pipe (Req, 6, Resp, R_Len, OK);
               if OK and then R_Len >= 1 then
                  declare
                     Err_Val : constant Natural := Natural (Resp (1));
                  begin
                     if Err_Val <= Vault_Error'Pos (Vault_Error'Last) then
                        Result := Vault_Error'Val (Err_Val);
                     else
                        Result := Err_Invalid;
                     end if;
                  end;
               else
                  Result := Err_No_Service;
               end if;
            end;
      end case;
   end Pipe_Delete;

   -- ── Pipe_Lock ─────────────────────────────────────────────

   procedure Pipe_Lock (Result : out Vault_Error) is
   begin
      case Active_Mode is
         when Mode_Embedded =>
            Vault_Storage.Lock;
            Result := Err_OK;

         when Mode_Service =>
            declare
               Req  : Pipe_Buffer := (others => 0);
               Resp : Pipe_Buffer;
               R_Len : Natural;
               OK   : Boolean;
            begin
               Req (1) := Vault_Crypto.Byte (16#44#);  -- Op_Lock
               Req (2) := 0;
               Call_Pipe (Req, 2, Resp, R_Len, OK);
               Result := (if OK then Err_OK else Err_No_Service);
            end;
      end case;
   end Pipe_Lock;

   -- ── Pipe_Count ────────────────────────────────────────────

   procedure Pipe_Count
      (Ex     : Exchange_Id;
       Count  : out Natural;
       Result : out Vault_Error)
   is
   begin
      Count := 0;

      case Active_Mode is
         when Mode_Embedded =>
            Count  := Vault_Storage.Key_Count (Ex);
            Result := Err_OK;

         when Mode_Service =>
            declare
               Req  : Pipe_Buffer := (others => 0);
               Resp : Pipe_Buffer;
               R_Len : Natural;
               OK   : Boolean;
            begin
               Req (1) := Vault_Crypto.Byte (16#49#);  -- Op_Count
               Req (2) := Vault_Crypto.Byte (Exchange_Id'Pos (Ex));
               Call_Pipe (Req, 2, Resp, R_Len, OK);

               if OK and then R_Len >= 7 then
                  declare
                     Err_Val : constant Natural := Natural (Resp (1));
                  begin
                     if Err_Val = 0 then
                        Count := Natural (Resp (4))
                               + Natural (Resp (5)) * 256
                               + Natural (Resp (6)) * 65536
                               + Natural (Resp (7)) * 16777216;
                        if Count > Max_Keys_Per_Exchange then
                           Count := Max_Keys_Per_Exchange;
                        end if;
                        Result := Err_OK;
                     else
                        Result := Err_Invalid;
                     end if;
                  end;
               else
                  Result := Err_No_Service;
               end if;
            end;
      end case;
   end Pipe_Count;

   -- ── Pipe_Set_Status ───────────────────────────────────────

   procedure Pipe_Set_Status
      (Ex     : Exchange_Id;
       Slot   : Slot_Index;
       Status : Key_Status;
       Result : out Vault_Error)
   is
   begin
      case Active_Mode is
         when Mode_Embedded =>
            declare
               OK : Boolean;
            begin
               Vault_Storage.Set_Key_Status (Ex, Slot, Status, OK);
               Result := (if OK then Err_OK else Err_Not_Found);
            end;

         when Mode_Service =>
            declare
               Req  : Pipe_Buffer := (others => 0);
               Resp : Pipe_Buffer;
               R_Len : Natural;
               OK   : Boolean;
               S_Val : constant Natural := Natural (Slot);
            begin
               Req (1) := Vault_Crypto.Byte (16#46#);  -- Op_Set_Status
               Req (2) := Vault_Crypto.Byte (Exchange_Id'Pos (Ex));
               Req (3) := Vault_Crypto.Byte (S_Val mod 256);
               Req (4) := Vault_Crypto.Byte ((S_Val / 256) mod 256);
               Req (5) := Vault_Crypto.Byte ((S_Val / 65536) mod 256);
               Req (6) := Vault_Crypto.Byte (S_Val / 16777216);
               Req (7) := Vault_Crypto.Byte (Key_Status'Pos (Status));

               Call_Pipe (Req, 7, Resp, R_Len, OK);
               if OK and then R_Len >= 1 then
                  declare
                     Err_Val : constant Natural := Natural (Resp (1));
                  begin
                     if Err_Val <= Vault_Error'Pos (Vault_Error'Last) then
                        Result := Vault_Error'Val (Err_Val);
                     else
                        Result := Err_Invalid;
                     end if;
                  end;
               else
                  Result := Err_No_Service;
               end if;
            end;
      end case;
   end Pipe_Set_Status;

end Vault_Pipe_Client;

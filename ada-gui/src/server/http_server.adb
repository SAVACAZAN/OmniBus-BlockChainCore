-- ============================================================
--  HTTP_Server body  —  Socket-based HTTP/1.1 + REST API
--
--  Pure Ada implementation using GNAT.Sockets.
--  No external dependencies (no AWS, no web framework).
-- ============================================================

pragma Ada_2022;

with Ada.Text_IO;
with Ada.Strings.Fixed;
with Ada.Directories;
with Ada.Streams;
with GNAT.Sockets;
with Exchange_Manager;
with Vault_Types;  use Vault_Types;

package body HTTP_Server is

   use GNAT.Sockets;
   use Ada.Strings.Fixed;

   Running      : Boolean := False;
   Frontend_Dir : String (1 .. 512) := (others => ' ');
   Frontend_Len : Natural := 0;
   Server_Sock  : Socket_Type;

   -- ── Set frontend directory ────────────────────────────────

   procedure Set_Frontend_Dir (Path : String) is
   begin
      Frontend_Len := Path'Length;
      Frontend_Dir (1 .. Frontend_Len) := Path;
   end Set_Frontend_Dir;

   -- ── Read entire file ──────────────────────────────────────

   function Read_File (Path : String) return String is
      use Ada.Directories;
   begin
      if not Exists (Path) then
         return "";
      end if;

      declare
         Size : constant Natural := Natural (Ada.Directories.Size (Path));
         Result : String (1 .. Size);
         F : Ada.Text_IO.File_Type;
         Pos : Natural := 0;
         Line : String (1 .. 4096);
         Last : Natural;
      begin
         Ada.Text_IO.Open (F, Ada.Text_IO.In_File, Path);
         while not Ada.Text_IO.End_Of_File (F) loop
            Ada.Text_IO.Get_Line (F, Line, Last);
            if Pos + Last + 1 <= Size then
               Result (Pos + 1 .. Pos + Last) := Line (1 .. Last);
               Pos := Pos + Last;
               if Pos < Size then
                  Pos := Pos + 1;
                  Result (Pos) := ASCII.LF;
               end if;
            end if;
         end loop;
         Ada.Text_IO.Close (F);
         return Result (1 .. Pos);
      exception
         when others =>
            if Ada.Text_IO.Is_Open (F) then
               Ada.Text_IO.Close (F);
            end if;
            return "";
      end;
   end Read_File;

   -- ── Parse exchange name ───────────────────────────────────

   function Parse_Exchange (S : String) return Exchange_Id is
   begin
      if S = "lcx" then return LCX;
      elsif S = "kraken" then return Kraken;
      elsif S = "coinbase" then return Coinbase;
      else return LCX;  -- default
      end if;
   end Parse_Exchange;

   -- ── Parse simple JSON value ───────────────────────────────

   function JSON_Value (Content : String; Key : String) return String is
      Search : constant String := """" & Key & """:""";
      Pos : constant Natural := Index (Content, Search);
   begin
      if Pos = 0 then
         return "";
      end if;

      declare
         Start : constant Natural := Pos + Search'Length;
         End_Pos : Natural := Start;
      begin
         while End_Pos <= Content'Last and then Content (End_Pos) /= '"' loop
            End_Pos := End_Pos + 1;
         end loop;
         return Content (Start .. End_Pos - 1);
      end;
   end JSON_Value;

   function JSON_Int (Content : String; Key : String) return Natural is
      Search : constant String := """" & Key & """:";
      Pos : constant Natural := Index (Content, Search);
   begin
      if Pos = 0 then return 0; end if;

      declare
         Start   : constant Natural := Pos + Search'Length;
         End_Pos : Natural := Start;
      begin
         while End_Pos <= Content'Last
            and then Content (End_Pos) in '0' .. '9'
         loop
            End_Pos := End_Pos + 1;
         end loop;
         if End_Pos > Start then
            return Natural'Value (Content (Start .. End_Pos - 1));
         end if;
         return 0;
      end;
   end JSON_Int;

   -- ── Error name to string ──────────────────────────────────

   function Error_Str (E : Vault_Error) return String is
   begin
      case E is
         when Err_OK         => return "OK";
         when Err_Not_Found  => return "Not Found";
         when Err_Decrypt    => return "Decrypt Failed";
         when Err_IO         => return "I/O Error";
         when Err_Locked     => return "Vault Locked";
         when Err_Invalid    => return "Invalid";
         when Err_No_Service => return "No Service";
         when Err_Full       => return "Vault Full";
         when Err_Duplicate  => return "Duplicate";
      end case;
   end Error_Str;

   -- ── Send HTTP response ────────────────────────────────────

   procedure Send_Response
      (Sock         : Socket_Type;
       Status_Code  : String;
       Content_Type : String;
       Content         : String)
   is
      use Ada.Streams;
      Header : constant String :=
         "HTTP/1.1 " & Status_Code & ASCII.CR & ASCII.LF &
         "Content-Type: " & Content_Type & ASCII.CR & ASCII.LF &
         "Access-Control-Allow-Origin: *" & ASCII.CR & ASCII.LF &
         "Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS"
            & ASCII.CR & ASCII.LF &
         "Access-Control-Allow-Headers: Content-Type" & ASCII.CR & ASCII.LF &
         "Content-Length:" & Natural'Image (Content'Length)
            & ASCII.CR & ASCII.LF &
         ASCII.CR & ASCII.LF &
         Content;

      Raw : Stream_Element_Array (1 .. Stream_Element_Offset (Header'Length));
      Last : Stream_Element_Offset;
   begin
      for I in Header'Range loop
         Raw (Stream_Element_Offset (I - Header'First + 1)) :=
            Stream_Element (Character'Pos (Header (I)));
      end loop;
      Send_Socket (Sock, Raw, Last);
   exception
      when others => null;
   end Send_Response;

   -- ── Handle one client connection ──────────────────────────

   procedure Handle_Client (Client : Socket_Type) is
      use Ada.Streams;
      Buf  : Stream_Element_Array (1 .. 16_384);
      Last : Stream_Element_Offset;
   begin
      Receive_Socket (Client, Buf, Last);

      if Last < 1 then
         Close_Socket (Client);
         return;
      end if;

      -- Convert to string
      declare
         Req : String (1 .. Natural (Last));
      begin
         for I in 1 .. Natural (Last) loop
            Req (I) := Character'Val (Natural (Buf (Stream_Element_Offset (I))));
         end loop;

         -- Parse method and path
         declare
            Space1 : constant Natural := Index (Req, " ");
            Space2 : Natural;
            Method : constant String :=
               (if Space1 > 1 then Req (1 .. Space1 - 1) else "GET");
         begin
            Space2 := Index (Req (Space1 + 1 .. Req'Last), " ");
            if Space2 = 0 then Space2 := Req'Last; end if;

            declare
               Path : constant String := Req (Space1 + 1 .. Space2 - 1);

               -- Find body (after double CRLF)
               Content_Start : constant Natural :=
                  Index (Req, "" & ASCII.CR & ASCII.LF
                     & ASCII.CR & ASCII.LF);
               Req_Content : constant String :=
                  (if Content_Start > 0 and then Content_Start + 4 <= Req'Last
                   then Req (Content_Start + 4 .. Req'Last)
                   else "");
            begin
               -- ── OPTIONS (CORS preflight) ──────────────────
               if Method = "OPTIONS" then
                  Send_Response (Client, "204 No Content", "text/plain", "");

               -- ── GET / → serve index.html ──────────────────
               elsif Path = "/" and then Method = "GET" then
                  declare
                     HTML : constant String := Read_File
                        (Frontend_Dir (1 .. Frontend_Len) & "/index.html");
                  begin
                     if HTML'Length > 0 then
                        Send_Response (Client, "200 OK", "text/html", HTML);
                     else
                        Send_Response (Client, "404 Not Found",
                           "text/plain", "index.html not found");
                     end if;
                  end;

               -- ── GET /api/status ───────────────────────────
               elsif Path = "/api/status" and then Method = "GET" then
                  declare
                     JSON : Exchange_Manager.JSON_String;
                     Len  : Natural;
                  begin
                     Exchange_Manager.Status_JSON (JSON, Len);
                     Send_Response (Client, "200 OK",
                        "application/json", JSON (1 .. Len));
                  end;

               -- ── GET /api/keys/:exchange ───────────────────
               elsif Index (Path, "/api/keys/") = Path'First
                  and then Method = "GET"
               then
                  declare
                     Ex_Str : constant String :=
                        Path (Path'First + 10 .. Path'Last);
                     -- Strip slot if present (e.g., /api/keys/lcx vs /api/keys/lcx/0)
                     Slash  : constant Natural := Index (Ex_Str, "/");
                     Ex_Name : constant String :=
                        (if Slash > 0
                         then Ex_Str (Ex_Str'First .. Slash - 1)
                         else Ex_Str);
                     Ex   : constant Exchange_Id := Parse_Exchange (Ex_Name);
                     JSON : Exchange_Manager.JSON_String;
                     Len  : Natural;
                  begin
                     Exchange_Manager.List_Keys_JSON (Ex, JSON, Len);
                     Send_Response (Client, "200 OK",
                        "application/json", JSON (1 .. Len));
                  end;

               -- ── POST /api/keys/:exchange (add) ────────────
               elsif Index (Path, "/api/keys/") = Path'First
                  and then Method = "POST"
               then
                  declare
                     Ex_Str : constant String :=
                        Path (Path'First + 10 .. Path'Last);
                     Ex     : constant Exchange_Id := Parse_Exchange (Ex_Str);
                     Name   : constant String := JSON_Value (Req_Content, "name");
                     Key    : constant String := JSON_Value (Req_Content, "apiKey");
                     Secret : constant String := JSON_Value (Req_Content, "secret");
                     St     : constant Natural := JSON_Int (Req_Content, "status");
                     Status : constant Key_Status :=
                        (if St <= Key_Status'Pos (Key_Status'Last)
                         then Key_Status'Val (St)
                         else Status_Free);
                     Result : Vault_Error;
                  begin
                     Exchange_Manager.Handle_Add_Key
                        (Ex, Name, Key, Secret, Status, Result);
                     Send_Response (Client, "200 OK",
                        "application/json",
                        "{""error"":""" & Error_Str (Result) & """}");
                  end;

               -- ── PUT /api/keys/:exchange/:slot (update) ────
               elsif Index (Path, "/api/keys/") = Path'First
                  and then Method = "PUT"
               then
                  declare
                     Rest   : constant String :=
                        Path (Path'First + 10 .. Path'Last);
                     Slash  : constant Natural := Index (Rest, "/");
                  begin
                     if Slash > 0 then
                        declare
                           Ex_Name : constant String :=
                              Rest (Rest'First .. Slash - 1);
                           Slot_Str : constant String :=
                              Rest (Slash + 1 .. Rest'Last);
                           Ex     : constant Exchange_Id :=
                              Parse_Exchange (Ex_Name);
                           Slot   : constant Slot_Index :=
                              Slot_Index (Natural'Value (Slot_Str));
                           Name   : constant String :=
                              JSON_Value (Req_Content, "name");
                           Key    : constant String :=
                              JSON_Value (Req_Content, "apiKey");
                           Secret : constant String :=
                              JSON_Value (Req_Content, "secret");
                           St     : constant Natural :=
                              JSON_Int (Req_Content, "status");
                           Status : constant Key_Status :=
                              (if St <= Key_Status'Pos (Key_Status'Last)
                               then Key_Status'Val (St)
                               else Status_Free);
                           Result : Vault_Error;
                        begin
                           Exchange_Manager.Handle_Update_Key
                              (Ex, Slot, Name, Key, Secret, Status, Result);
                           Send_Response (Client, "200 OK",
                              "application/json",
                              "{""error"":""" & Error_Str (Result) & """}");
                        end;
                     else
                        Send_Response (Client, "400 Bad Request",
                           "application/json",
                           "{""error"":""Missing slot""}");
                     end if;
                  end;

               -- ── DELETE /api/keys/:exchange/:slot ──────────
               elsif Index (Path, "/api/keys/") = Path'First
                  and then Method = "DELETE"
               then
                  declare
                     Rest   : constant String :=
                        Path (Path'First + 10 .. Path'Last);
                     Slash  : constant Natural := Index (Rest, "/");
                  begin
                     if Slash > 0 then
                        declare
                           Ex_Name : constant String :=
                              Rest (Rest'First .. Slash - 1);
                           Slot_Str : constant String :=
                              Rest (Slash + 1 .. Rest'Last);
                           Ex     : constant Exchange_Id :=
                              Parse_Exchange (Ex_Name);
                           Slot   : constant Slot_Index :=
                              Slot_Index (Natural'Value (Slot_Str));
                           Result : Vault_Error;
                        begin
                           Exchange_Manager.Handle_Delete_Key (Ex, Slot, Result);
                           Send_Response (Client, "200 OK",
                              "application/json",
                              "{""error"":""" & Error_Str (Result) & """}");
                        end;
                     else
                        Send_Response (Client, "400 Bad Request",
                           "application/json",
                           "{""error"":""Missing slot""}");
                     end if;
                  end;

               -- ── POST /api/lock ────────────────────────────
               elsif Path = "/api/lock" and then Method = "POST" then
                  declare
                     Result : Vault_Error;
                  begin
                     Exchange_Manager.Handle_Lock (Result);
                     Send_Response (Client, "200 OK",
                        "application/json",
                        "{""error"":""" & Error_Str (Result) & """}");
                  end;

               -- ── POST /api/unlock ──────────────────────────
               elsif Path = "/api/unlock" and then Method = "POST" then
                  declare
                     Result : Vault_Error;
                  begin
                     Exchange_Manager.Handle_Unlock (Result);
                     Send_Response (Client, "200 OK",
                        "application/json",
                        "{""error"":""" & Error_Str (Result) & """}");
                  end;

               -- ── 404 ──────────────────────────────────────
               else
                  Send_Response (Client, "404 Not Found",
                     "application/json", "{""error"":""Not Found""}");
               end if;
            end;
         end;
      end;

      Close_Socket (Client);

   exception
      when others =>
         begin
            Close_Socket (Client);
         exception
            when others => null;
         end;
   end Handle_Client;

   -- ── Start ─────────────────────────────────────────────────

   procedure Start (Port : Positive := Default_Port) is
      Address : Sock_Addr_Type;
   begin
      Running := True;

      Create_Socket (Server_Sock, Family_Inet, Socket_Stream);
      Set_Socket_Option (Server_Sock, Socket_Level,
         (Reuse_Address, True));

      Address.Addr := Any_Inet_Addr;
      Address.Port := Port_Type (Port);
      Bind_Socket (Server_Sock, Address);
      Listen_Socket (Server_Sock, 5);

      Ada.Text_IO.Put_Line
         ("OmniBus Ada GUI server on http://localhost:"
          & Positive'Image (Port));
      Ada.Text_IO.Put_Line
         ("Frontend: " & Frontend_Dir (1 .. Frontend_Len));

      while Running loop
         declare
            Client  : Socket_Type;
            Cli_Addr : Sock_Addr_Type;
         begin
            Accept_Socket (Server_Sock, Client, Cli_Addr);
            Handle_Client (Client);
         exception
            when others =>
               if not Running then exit; end if;
         end;
      end loop;

   exception
      when E : others =>
         Ada.Text_IO.Put_Line ("Server error — shutting down");
         begin
            Close_Socket (Server_Sock);
         exception
            when others => null;
         end;
   end Start;

   -- ── Stop ──────────────────────────────────────────────────

   procedure Stop is
   begin
      Running := False;
      begin
         Close_Socket (Server_Sock);
      exception
         when others => null;
      end;
   end Stop;

end HTTP_Server;

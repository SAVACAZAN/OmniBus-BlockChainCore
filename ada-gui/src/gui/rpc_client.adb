-- ============================================================
--  RPC_Client body  --  HTTP + JSON-RPC over GNAT.Sockets
-- ============================================================

pragma Ada_2022;

with GNAT.Sockets;
with Ada.Calendar;
with Ada.Streams;
with Ada.Strings.Fixed;

package body RPC_Client is

   use GNAT.Sockets;
   use Ada.Streams;

   Current_Host : String (1 .. 64)  := (others => ' ');
   Host_Len     : Natural           := 0;
   Current_Port : Positive          := Default_Port;
   Connected    : Boolean           := False;

   -- ── Config ────────────────────────────────────────────────

   procedure Set_Host (Host : String) is
      L : constant Natural := Natural'Min (Host'Length, 64);
   begin
      Current_Host (1 .. L) := Host (Host'First .. Host'First + L - 1);
      Host_Len := L;
   end Set_Host;

   procedure Set_Port (Port : Positive) is
   begin
      Current_Port := Port;
   end Set_Port;

   function Is_Connected return Boolean is (Connected);

   -- ── Internal: send HTTP POST, receive response ────────────

   procedure HTTP_Post
     (Content : String;
      Result  : out RPC_Result)
   is
      Sock   : Socket_Type;
      Addr   : Sock_Addr_Type;
      Host_S : constant String :=
        (if Host_Len > 0 then Current_Host (1 .. Host_Len) else Default_Host);

      function To_SEA (S : String) return Stream_Element_Array is
         R : Stream_Element_Array (1 .. Stream_Element_Offset (S'Length));
      begin
         for I in S'Range loop
            R (Stream_Element_Offset (I - S'First + 1)) :=
               Stream_Element (Character'Pos (S (I)));
         end loop;
         return R;
      end To_SEA;

      Request : constant String :=
        "POST / HTTP/1.1" & ASCII.CR & ASCII.LF &
        "Host: " & Host_S & ASCII.CR & ASCII.LF &
        "Content-Type: application/json" & ASCII.CR & ASCII.LF &
        "Content-Length:" & Natural'Image (Content'Length) & ASCII.CR & ASCII.LF &
        "Connection: close" & ASCII.CR & ASCII.LF &
        ASCII.CR & ASCII.LF &
        Content;

      Buf  : Stream_Element_Array (1 .. Stream_Element_Offset (Max_Response));
      Last : Stream_Element_Offset;
      Pos  : Natural := 0;
   begin
      Result := (Data => (others => ' '), Len => 0, Success => False);

      Create_Socket (Sock);
      Addr.Addr := Inet_Addr (Host_S);
      Addr.Port := Port_Type (Current_Port);

      -- Set short socket timeouts (500ms) so GUI doesn't freeze
      declare
         use type Ada.Calendar.Time;
         Timeout : constant Duration := 0.5;
      begin
         Set_Socket_Option
           (Sock, Socket_Level,
            (Name    => Send_Timeout,
             Timeout => Timeout));
         Set_Socket_Option
           (Sock, Socket_Level,
            (Name    => Receive_Timeout,
             Timeout => Timeout));
      end;

      begin
         Connect_Socket (Sock, Addr);
      exception
         when others =>
            Close_Socket (Sock);
            Connected := False;
            return;
      end;

      Connected := True;

      -- Send request
      declare
         Data : constant Stream_Element_Array := To_SEA (Request);
         Sent : Stream_Element_Offset;
      begin
         Send_Socket (Sock, Data, Sent);
      end;

      -- Receive response
      loop
         begin
            Receive_Socket (Sock, Buf, Last);
            exit when Last < Buf'First;

            for I in Buf'First .. Last loop
               if Pos < Max_Response then
                  Pos := Pos + 1;
                  Result.Data (Pos) :=
                     Character'Val (Integer (Buf (I)));
               end if;
            end loop;
         exception
            when others => exit;
         end;
      end loop;

      Close_Socket (Sock);

      Result.Len := Pos;

      -- Skip HTTP headers -- find the double CRLF
      declare
         Full : constant String := Result.Data (1 .. Pos);
         Idx  : constant Natural :=
            Ada.Strings.Fixed.Index (Full, ASCII.CR & ASCII.LF &
                                           ASCII.CR & ASCII.LF);
      begin
         if Idx > 0 and then Idx + 4 <= Pos then
            declare
               Body_Start : constant Natural := Idx + 4;
               Body_Len   : constant Natural := Pos - Body_Start + 1;
            begin
               Result.Data (1 .. Body_Len) :=
                  Full (Body_Start .. Pos);
               Result.Len := Body_Len;
            end;
         end if;
      end;

      Result.Success := True;

   exception
      when others =>
         Connected := False;
         Result.Success := False;
         begin
            Close_Socket (Sock);
         exception
            when others => null;
         end;
   end HTTP_Post;

   -- ── Raw RPC call ──────────────────────────────────────────

   procedure Call
     (Method : String;
      Params : String;
      Result : out RPC_Result)
   is
      Payload : constant String :=
        "{""jsonrpc"":""2.0"",""id"":1,""method"":""" & Method &
        """,""params"":" & Params & "}";
   begin
      HTTP_Post (Payload, Result);
   end Call;

   -- ── JSON helpers ──────────────────────────────────────────

   function Extract_String
     (JSON : String; Key : String) return String
   is
      use Ada.Strings.Fixed;
      Pattern : constant String := """" & Key & """:""";
      Idx     : constant Natural := Index (JSON, Pattern);
   begin
      if Idx = 0 then
         return "";
      end if;

      declare
         Start : constant Natural := Idx + Pattern'Length;
         End_Q : constant Natural := Index (JSON (Start .. JSON'Last), """");
      begin
         if End_Q = 0 then
            return "";
         end if;
         return JSON (Start .. End_Q - 1);
      end;
   end Extract_String;

   function Extract_Number
     (JSON : String; Key : String) return Long_Long_Integer
   is
      use Ada.Strings.Fixed;
      Pattern : constant String := """" & Key & """:";
      Idx     : constant Natural := Index (JSON, Pattern);
   begin
      if Idx = 0 then
         return 0;
      end if;

      declare
         Start : Natural := Idx + Pattern'Length;
         Finish : Natural := Start;
      begin
         -- Skip spaces
         while Start <= JSON'Last and then JSON (Start) = ' ' loop
            Start := Start + 1;
         end loop;
         Finish := Start;
         while Finish <= JSON'Last and then
               (JSON (Finish) in '0' .. '9' or else JSON (Finish) = '-')
         loop
            Finish := Finish + 1;
         end loop;
         if Finish > Start then
            return Long_Long_Integer'Value (JSON (Start .. Finish - 1));
         end if;
      end;
      return 0;
   exception
      when others => return 0;
   end Extract_Number;

   -- ── High-level methods ────────────────────────────────────

   procedure Get_Block_Height (Height : out Natural; OK : out Boolean) is
      R : RPC_Result;
   begin
      Call ("getblockcount", "{}", R);
      if R.Success then
         Height := Natural (Extract_Number (R.Data (1 .. R.Len), "result"));
         OK := True;
      else
         Height := 0;
         OK := False;
      end if;
   end Get_Block_Height;

   procedure Get_Network_Info (Result : out RPC_Result) is
   begin
      Call ("getnetworkinfo", "{}", Result);
   end Get_Network_Info;

   procedure Get_Mempool (Result : out RPC_Result) is
   begin
      Call ("getmempoolinfo", "{}", Result);
   end Get_Mempool;

   procedure Get_Balance
     (Address : String;
      Result  : out RPC_Result)
   is
   begin
      Call ("getbalance", "{""address"":""" & Address & """}", Result);
   end Get_Balance;

   procedure Send_Transaction
     (From_Addr : String;
      To_Addr   : String;
      Amount    : Long_Long_Integer;
      Fee       : Long_Long_Integer;
      Result    : out RPC_Result)
   is
      Amt : constant String := Long_Long_Integer'Image (Amount);
      F   : constant String := Long_Long_Integer'Image (Fee);
   begin
      Call ("sendtransaction",
         "{""from"":""" & From_Addr &
         """,""to"":""" & To_Addr &
         """,""amount"":" & Amt (2 .. Amt'Last) &
         ",""fee"":" & F (2 .. F'Last) & "}", Result);
   end Send_Transaction;

   procedure Get_Block
     (Height : Natural;
      Result : out RPC_Result)
   is
      H : constant String := Natural'Image (Height);
   begin
      Call ("getblock", "{""height"":" & H (2 .. H'Last) & "}", Result);
   end Get_Block;

   procedure Get_Block_By_Hash
     (Hash   : String;
      Result : out RPC_Result)
   is
   begin
      Call ("getblock", "{""hash"":""" & Hash & """}", Result);
   end Get_Block_By_Hash;

   procedure Get_Peer_List (Result : out RPC_Result) is
   begin
      Call ("getpeerinfo", "{}", Result);
   end Get_Peer_List;

   procedure Get_Mining_Info (Result : out RPC_Result) is
   begin
      Call ("getmininginfo", "{}", Result);
   end Get_Mining_Info;

   procedure Get_Transactions
     (Address : String;
      Result  : out RPC_Result)
   is
   begin
      Call ("gettransactions", "{""address"":""" & Address & """}", Result);
   end Get_Transactions;

   procedure Execute_Command
     (Command : String;
      Result  : out RPC_Result)
   is
      use Ada.Strings.Fixed;
      Space : constant Natural := Index (Command, " ");
   begin
      if Space > 0 then
         Call (Command (Command'First .. Space - 1),
              "{""args"":""" & Command (Space + 1 .. Command'Last) & """}",
              Result);
      else
         Call (Command, "{}", Result);
      end if;
   end Execute_Command;

end RPC_Client;

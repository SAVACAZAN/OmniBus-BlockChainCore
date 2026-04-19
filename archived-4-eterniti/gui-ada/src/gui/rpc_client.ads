-- ============================================================
--  RPC_Client  --  JSON-RPC 2.0 client for OmniBus Zig node
--
--  Connects to localhost:8332 via HTTP POST
--  Methods mirror the Zig RPC server endpoints
-- ============================================================

pragma Ada_2022;

package RPC_Client
   with SPARK_Mode => Off
is

   Default_Host : constant String := "127.0.0.1";
   Default_Port : constant        := 8332;

   -- ── Response buffer ───────────────────────────────────────
   Max_Response : constant := 65_536;
   subtype Response_String is String (1 .. Max_Response);

   type RPC_Result is record
      Data    : Response_String := (others => ' ');
      Len     : Natural         := 0;
      Success : Boolean         := False;
   end record;

   -- ── Configuration ─────────────────────────────────────────
   procedure Set_Host (Host : String);
   procedure Set_Port (Port : Positive);

   -- ── Raw RPC call ──────────────────────────────────────────
   procedure Call
     (Method : String;
      Params : String;
      Result : out RPC_Result);

   -- ── High-level methods ────────────────────────────────────

   procedure Get_Block_Height (Height : out Natural; OK : out Boolean);

   procedure Get_Network_Info (Result : out RPC_Result);

   procedure Get_Mempool (Result : out RPC_Result);

   procedure Get_Balance
     (Address : String;
      Result  : out RPC_Result);

   procedure Send_Transaction
     (From_Addr : String;
      To_Addr   : String;
      Amount    : Long_Long_Integer;
      Fee       : Long_Long_Integer;
      Result    : out RPC_Result);

   procedure Get_Block
     (Height : Natural;
      Result : out RPC_Result);

   procedure Get_Block_By_Hash
     (Hash   : String;
      Result : out RPC_Result);

   procedure Get_Peer_List (Result : out RPC_Result);

   procedure Get_Mining_Info (Result : out RPC_Result);

   procedure Get_Transactions
     (Address : String;
      Result  : out RPC_Result);

   procedure Execute_Command
     (Command : String;
      Result  : out RPC_Result);

   -- ── JSON helpers ──────────────────────────────────────────
   function Extract_String
     (JSON : String; Key : String) return String;

   function Extract_Number
     (JSON : String; Key : String) return Long_Long_Integer;

   function Is_Connected return Boolean;

end RPC_Client;

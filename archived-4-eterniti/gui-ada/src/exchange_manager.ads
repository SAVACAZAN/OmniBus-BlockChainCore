-- ============================================================
--  Exchange_Manager  —  High-level exchange key operations
--
--  Facade over Vault_Storage / Vault_Pipe_Client.
--  JSON serialization for HTTP API responses.
-- ============================================================

pragma Ada_2022;

with Vault_Types;        use Vault_Types;
with Vault_Pipe_Client;  use Vault_Pipe_Client;

package Exchange_Manager
   with SPARK_Mode => On
is

   -- ── Initialize (auto-detect service or embedded) ──────────

   procedure Init (Success : out Boolean);

   -- ── JSON responses for HTTP API ───────────────────────────

   Max_JSON_Length : constant := 32_768;

   subtype JSON_String is String (1 .. Max_JSON_Length);

   -- List all keys for an exchange (masked secrets)
   procedure List_Keys_JSON
      (Ex   : Exchange_Id;
       JSON : out JSON_String;
       Len  : out Natural);

   -- Get vault status
   procedure Status_JSON
      (JSON : out JSON_String;
       Len  : out Natural);

   -- ── CRUD via HTTP API ─────────────────────────────────────

   procedure Handle_Add_Key
      (Ex       : Exchange_Id;
       Name     : String;
       Api_Key  : String;
       Secret   : String;
       Status   : Key_Status;
       Result   : out Vault_Error)
      with Pre => Name'Length <= Max_Name_Length
                  and then Api_Key'Length <= Max_Key_Length
                  and then Secret'Length <= Max_Secret_Length;

   procedure Handle_Delete_Key
      (Ex     : Exchange_Id;
       Slot   : Slot_Index;
       Result : out Vault_Error);

   procedure Handle_Update_Key
      (Ex      : Exchange_Id;
       Slot    : Slot_Index;
       Name    : String;
       Api_Key : String;
       Secret  : String;
       Status  : Key_Status;
       Result  : out Vault_Error)
      with Pre => Name'Length <= Max_Name_Length
                  and then Api_Key'Length <= Max_Key_Length
                  and then Secret'Length <= Max_Secret_Length;

   procedure Handle_Lock (Result : out Vault_Error);

   procedure Handle_Unlock (Result : out Vault_Error);

   procedure Handle_Set_Status
      (Ex     : Exchange_Id;
       Slot   : Slot_Index;
       Status : Key_Status;
       Result : out Vault_Error);

end Exchange_Manager;

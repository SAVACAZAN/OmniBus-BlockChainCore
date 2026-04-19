-- ============================================================
--  Vault_Pipe_Client  —  Named Pipe client for vault_service
--
--  Talks to OmnibusSidebar vault_service.exe via
--  \\.\pipe\OmnibusVault using the v4 binary protocol.
--
--  Dual-mode: Service (pipe) or Embedded (direct DPAPI)
-- ============================================================

pragma Ada_2022;

with Vault_Types;  use Vault_Types;

package Vault_Pipe_Client
   with SPARK_Mode => On
is

   -- ── Mode ──────────────────────────────────────────────────

   type Client_Mode is (Mode_Service, Mode_Embedded);

   -- ── Initialize ────────────────────────────────────────────

   procedure Init
      (Mode    : Client_Mode := Mode_Embedded;
       Success : out Boolean);

   -- ── Service operations (pipe protocol) ────────────────────

   procedure Pipe_Add
      (Ex       : Exchange_Id;
       Name     : String;
       Api_Key  : String;
       Secret   : String;
       Result   : out Vault_Error)
      with Pre => Name'Length <= Max_Name_Length
                  and then Api_Key'Length <= Max_Key_Length
                  and then Secret'Length <= Max_Secret_Length;

   procedure Pipe_Delete
      (Ex     : Exchange_Id;
       Slot   : Slot_Index;
       Result : out Vault_Error);

   procedure Pipe_Lock
      (Result : out Vault_Error);

   procedure Pipe_Count
      (Ex     : Exchange_Id;
       Count  : out Natural;
       Result : out Vault_Error)
      with Post => Count <= Max_Keys_Per_Exchange;

   procedure Pipe_Set_Status
      (Ex     : Exchange_Id;
       Slot   : Slot_Index;
       Status : Key_Status;
       Result : out Vault_Error);

   -- ── Service availability ──────────────────────────────────

   function Service_Available return Boolean;

   -- ── Current mode ──────────────────────────────────────────

   function Current_Mode return Client_Mode;

end Vault_Pipe_Client;

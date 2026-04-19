-- ============================================================
--  Vault_Storage  —  Multi-key vault with DPAPI persistence
--
--  SPARK_Mode On: all state transitions verified
--  Binary format v4 compatible with SuperVault (OMNV magic)
--  File: %APPDATA%\OmniBus-Ada\exchange-keys.vault
-- ============================================================

pragma Ada_2022;

with Vault_Types;  use Vault_Types;

package Vault_Storage
   with SPARK_Mode => On
is

   -- ── State ─────────────────────────────────────────────────

   function Is_Loaded return Boolean;

   -- ── Lifecycle ─────────────────────────────────────────────

   procedure Init (Success : out Boolean)
      with Post => (if Success then Is_Loaded);

   procedure Save (Success : out Boolean)
      with Pre => Is_Loaded;

   procedure Lock
      with Post => not Is_Loaded;

   -- ── Key management ────────────────────────────────────────

   procedure Add_Key
      (Ex      : Exchange_Id;
       Name    : Name_String;
       Api_Key : Key_String;
       Secret  : Secret_String;
       Status  : Key_Status;
       Success : out Boolean)
      with Pre => Is_Loaded;

   procedure Delete_Key
      (Ex      : Exchange_Id;
       Slot    : Slot_Index;
       Success : out Boolean)
      with Pre => Is_Loaded;

   procedure Update_Key
      (Ex      : Exchange_Id;
       Slot    : Slot_Index;
       Name    : Name_String;
       Api_Key : Key_String;
       Secret  : Secret_String;
       Status  : Key_Status;
       Success : out Boolean)
      with Pre => Is_Loaded;

   -- ── Queries ───────────────────────────────────────────────

   function Get_Key
      (Ex   : Exchange_Id;
       Slot : Slot_Index) return Key_Entry
      with Pre => Is_Loaded;

   function Key_Count (Ex : Exchange_Id) return Natural
      with Pre  => Is_Loaded,
           Post => Key_Count'Result <= Max_Keys_Per_Exchange;

   function Has_Keys (Ex : Exchange_Id) return Boolean
      with Pre => Is_Loaded;

   -- ── Status ────────────────────────────────────────────────

   procedure Set_Key_Status
      (Ex      : Exchange_Id;
       Slot    : Slot_Index;
       Status  : Key_Status;
       Success : out Boolean)
      with Pre => Is_Loaded;

   -- ── Vault file path ──────────────────────────────────────

   function Vault_File_Path return String;

end Vault_Storage;

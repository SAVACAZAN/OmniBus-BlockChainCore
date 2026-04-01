-- ============================================================
--  Vault_Types  —  Core types for SuperVault v4 protocol
--
--  SPARK_Mode verified: all ranges bounded, no overflow
--  Compatible with OmnibusSidebar vault_core.h v4
-- ============================================================

pragma Ada_2022;

package Vault_Types
   with SPARK_Mode => On,
        Pure
is

   -- ── Exchange identifiers ──────────────────────────────────

   type Exchange_Id is (LCX, Kraken, Coinbase)
      with Size => 8;

   for Exchange_Id use (LCX => 0, Kraken => 1, Coinbase => 2);

   Exchange_Count : constant := 3;

   -- ── Key status ────────────────────────────────────────────

   type Key_Status is (Status_Free, Status_Paid, Status_Not_Paid)
      with Size => 8;

   for Key_Status use
      (Status_Free     => 0,
       Status_Paid     => 1,
       Status_Not_Paid => 2);

   -- ── Constants ─────────────────────────────────────────────

   Max_Keys_Per_Exchange : constant := 8;
   Max_Name_Length       : constant := 64;
   Max_Key_Length        : constant := 8_192;
   Max_Secret_Length     : constant := 16_384;

   Vault_Magic   : constant := 16#4F4D4E56#;  -- "OMNV"
   Vault_Version : constant := 4;

   -- ── Bounded strings ───────────────────────────────────────

   subtype Name_Index   is Natural range 0 .. Max_Name_Length;
   subtype Key_Index    is Natural range 0 .. Max_Key_Length;
   subtype Secret_Index is Natural range 0 .. Max_Secret_Length;

   type Name_String is record
      Data : String (1 .. Max_Name_Length) := (others => ' ');
      Len  : Name_Index := 0;
   end record
      with Dynamic_Predicate => Name_String.Len <= Max_Name_Length;

   type Key_String is record
      Data : String (1 .. Max_Key_Length) := (others => ' ');
      Len  : Key_Index := 0;
   end record
      with Dynamic_Predicate => Key_String.Len <= Max_Key_Length;

   type Secret_String is record
      Data : String (1 .. Max_Secret_Length) := (others => ' ');
      Len  : Secret_Index := 0;
   end record
      with Dynamic_Predicate => Secret_String.Len <= Max_Secret_Length;

   -- ── Key entry ─────────────────────────────────────────────

   type Key_Entry is record
      In_Use     : Boolean    := False;
      Status     : Key_Status := Status_Free;
      Name       : Name_String;
      Api_Key    : Key_String;
      Api_Secret : Secret_String;
   end record;

   Empty_Key_Entry : constant Key_Entry :=
      (In_Use     => False,
       Status     => Status_Free,
       Name       => (Data => (others => ' '), Len => 0),
       Api_Key    => (Data => (others => ' '), Len => 0),
       Api_Secret => (Data => (others => ' '), Len => 0));

   -- ── Slot array per exchange ───────────────────────────────

   type Slot_Index is range 0 .. Max_Keys_Per_Exchange - 1;

   type Slot_Array is array (Slot_Index) of Key_Entry;

   type Exchange_Store is array (Exchange_Id) of Slot_Array;

   -- ── Pipe protocol opcodes ─────────────────────────────────

   type Vault_Opcode is
      (Op_Init,
       Op_Add,
       Op_Get_Meta,
       Op_Delete,
       Op_Lock,
       Op_List,
       Op_Set_Status,
       Op_Save,
       Op_Count,
       Op_Get_Secret,
       Op_Set_Status2,
       Op_Get_Trading_Creds)
      with Size => 8;

   for Vault_Opcode use
      (Op_Init             => 16#40#,
       Op_Add              => 16#41#,
       Op_Get_Meta         => 16#42#,
       Op_Delete           => 16#43#,
       Op_Lock             => 16#44#,
       Op_List             => 16#45#,
       Op_Set_Status       => 16#46#,
       Op_Save             => 16#48#,
       Op_Count            => 16#49#,
       Op_Get_Secret       => 16#4A#,
       Op_Set_Status2      => 16#4B#,
       Op_Get_Trading_Creds => 16#4C#);

   -- ── Error codes ───────────────────────────────────────────

   type Vault_Error is
      (Err_OK,
       Err_Not_Found,
       Err_Decrypt,
       Err_IO,
       Err_Locked,
       Err_Invalid,
       Err_No_Service,
       Err_Full,
       Err_Duplicate)
      with Size => 8;

   for Vault_Error use
      (Err_OK         => 0,
       Err_Not_Found  => 1,
       Err_Decrypt    => 2,
       Err_IO         => 3,
       Err_Locked     => 4,
       Err_Invalid    => 5,
       Err_No_Service => 6,
       Err_Full       => 7,
       Err_Duplicate  => 8);

   -- ── Helper functions ──────────────────────────────────────

   function Exchange_Name (Ex : Exchange_Id) return String
      with Post => Exchange_Name'Result'Length in 3 .. 8;

   function Status_Name (St : Key_Status) return String
      with Post => Status_Name'Result'Length in 4 .. 8;

   function To_Name_String (S : String) return Name_String
      with Pre => S'Length <= Max_Name_Length;

   function To_Key_String (S : String) return Key_String
      with Pre => S'Length <= Max_Key_Length;

   function To_Secret_String (S : String) return Secret_String
      with Pre => S'Length <= Max_Secret_Length;

end Vault_Types;

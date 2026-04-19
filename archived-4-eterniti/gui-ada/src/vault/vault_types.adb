-- ============================================================
--  Vault_Types body  —  Helper implementations
-- ============================================================

pragma Ada_2022;

package body Vault_Types
   with SPARK_Mode => On
is

   function Exchange_Name (Ex : Exchange_Id) return String is
   begin
      case Ex is
         when LCX      => return "LCX";
         when Kraken   => return "Kraken";
         when Coinbase => return "Coinbase";
      end case;
   end Exchange_Name;

   function Status_Name (St : Key_Status) return String is
   begin
      case St is
         when Status_Free     => return "Free";
         when Status_Paid     => return "Paid";
         when Status_Not_Paid => return "Not Paid";
      end case;
   end Status_Name;

   function To_Name_String (S : String) return Name_String is
      Result : Name_String;
   begin
      Result.Len := S'Length;
      Result.Data (1 .. S'Length) := S;
      return Result;
   end To_Name_String;

   function To_Key_String (S : String) return Key_String is
      Result : Key_String;
   begin
      Result.Len := S'Length;
      Result.Data (1 .. S'Length) := S;
      return Result;
   end To_Key_String;

   function To_Secret_String (S : String) return Secret_String is
      Result : Secret_String;
   begin
      Result.Len := S'Length;
      Result.Data (1 .. S'Length) := S;
      return Result;
   end To_Secret_String;

end Vault_Types;

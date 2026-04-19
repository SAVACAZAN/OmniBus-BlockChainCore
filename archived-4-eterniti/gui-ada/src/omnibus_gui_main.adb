--  ============================================================
--  OmniBus Ada GUI  --  Main entry point
--
--  SPARK-verified vault backend + HTML frontend
--  Serves on http://localhost:8340
--
--  Usage:
--    omnibus-ada-gui                    (default port 8340)
--    omnibus-ada-gui --port 9000        (custom port)
--  ============================================================

pragma Ada_2022;

with Ada.Text_IO;
with Ada.Command_Line;
with Ada.Directories;
with Exchange_Manager;
with HTTP_Server;
with Vault_Types;
with Vault_Pipe_Client;

procedure Omnibus_Gui_Main is

   Port : Positive := HTTP_Server.Default_Port;

   --  Parse command line

   procedure Parse_Args is
      use Ada.Command_Line;
   begin
      for I in 1 .. Argument_Count loop
         if Argument (I) = "--port" and then I < Argument_Count then
            Port := Positive'Value (Argument (I + 1));
         end if;
      end loop;
   exception
      when others => null;
   end Parse_Args;

   --  Find frontend directory

   function Find_Frontend return String is
   begin
      if Ada.Directories.Exists ("frontend/index.html") then
         return "frontend";
      elsif Ada.Directories.Exists ("../frontend/index.html") then
         return "../frontend";
      elsif Ada.Directories.Exists ("../ada-gui/frontend/index.html") then
         return "../ada-gui/frontend";
      end if;
      return "frontend";
   end Find_Frontend;

   OK : Boolean;

begin
   Ada.Text_IO.Put_Line ("========================================");
   Ada.Text_IO.Put_Line ("  OmniBus Ada GUI -- SPARK Verified");
   Ada.Text_IO.Put_Line ("  SuperVault DPAPI + HTML Frontend");
   Ada.Text_IO.Put_Line ("========================================");
   Ada.Text_IO.New_Line;

   Parse_Args;

   --  Initialize vault
   Ada.Text_IO.Put ("Initializing vault... ");
   Exchange_Manager.Init (OK);
   if OK then
      Ada.Text_IO.Put_Line ("OK");
   else
      Ada.Text_IO.Put_Line ("FAILED (starting with empty vault)");
   end if;

   Ada.Text_IO.Put_Line
      ("Vault file: " & Vault_Types.Exchange_Name (Vault_Types.LCX));

   --  Set frontend path
   declare
      FE : constant String := Find_Frontend;
   begin
      HTTP_Server.Set_Frontend_Dir (FE);
      Ada.Text_IO.Put_Line ("Frontend:   " & FE & "/index.html");
   end;

   Ada.Text_IO.New_Line;
   Ada.Text_IO.Put_Line ("Exchanges: LCX | Kraken | Coinbase");
   Ada.Text_IO.Put_Line ("Max keys:  8 per exchange");
   Ada.Text_IO.Put_Line ("Encryption: Windows DPAPI");

   declare
      use Vault_Pipe_Client;
      Mode_Str : constant String :=
         (if Current_Mode = Mode_Service
          then "Service (pipe)" else "Embedded (DPAPI)");
   begin
      Ada.Text_IO.Put_Line ("Mode:      " & Mode_Str);
   end;

   Ada.Text_IO.New_Line;

   --  Start server (blocking)
   HTTP_Server.Start (Port);

exception
   when others =>
      Ada.Text_IO.Put_Line ("Fatal error -- exiting.");
      HTTP_Server.Stop;
end Omnibus_Gui_Main;

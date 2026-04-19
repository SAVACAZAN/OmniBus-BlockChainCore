-- ============================================================
--  OmniBus Ada GtkAda GUI  --  Main entry point
--
--  Native GtkAda desktop application for OmniBus blockchain.
--  10 tabs: Overview, Multi-Wallet, Send, Receive, Transactions,
--           Mining, Network, Block Explorer, Console, Exchange Keys
--
--  Connects to Zig blockchain node via JSON-RPC on port 8332
--  Vault encryption via SPARK-verified DPAPI backend
-- ============================================================

pragma Ada_2022;

with Ada.Text_IO;
with Ada.Command_Line;
with Gtk.Main;
with Gtk.Widget;
with Gtk.Css_Provider;
with Gtk.Style_Provider;
with Gtk.Style_Context;
with Gdk.Screen;
with Glib;
with Glib.Error;
with Glib.Main;

with Dark_Theme;
with Main_Window;
with RPC_Client;
with Exchange_Manager;
with Vault_Pipe_Client; use Vault_Pipe_Client;
with Welcome_Dialog;

procedure Omnibus_Gtk_Main is

   Win : aliased Main_Window.Main_Window_Record;

   -- ── Parse command line ────────────────────────────────────

   procedure Parse_Args is
      use Ada.Command_Line;
   begin
      for I in 1 .. Argument_Count loop
         if Argument (I) = "--rpc-host" and then I < Argument_Count then
            RPC_Client.Set_Host (Argument (I + 1));
         elsif Argument (I) = "--rpc-port" and then I < Argument_Count then
            RPC_Client.Set_Port (Positive'Value (Argument (I + 1)));
         end if;
      end loop;
   exception
      when others => null;
   end Parse_Args;

   -- ── Apply dark theme CSS ─────────────────────────────────

   procedure Apply_Theme is
      use Gtk.Css_Provider;
      Provider : Gtk_Css_Provider;
      Screen   : constant Gdk.Screen.Gdk_Screen :=
         Gdk.Screen.Get_Default;
      Error    : aliased Glib.Error.GError;
      Success  : Boolean;
      pragma Unreferenced (Success);
   begin
      Gtk_New (Provider);
      Success := Provider.Load_From_Data (Dark_Theme.CSS, Error'Access);

      Gtk.Style_Context.Add_Provider_For_Screen
        (Screen,
         +Provider,
         Gtk.Style_Provider.Priority_Application);
   end Apply_Theme;

   -- ── Timer callback for RPC refresh ────────────────────────

   Timer_ID : Glib.Main.G_Source_Id := 0;
   pragma Unreferenced (Timer_ID);

   package Timer_Cb is new Glib.Main.Generic_Sources (Boolean);

   function On_Timer (Dummy : Boolean) return Boolean is
      pragma Unreferenced (Dummy);
   begin
      Main_Window.Refresh_All (Win);
      return True;  -- keep timer running
   exception
      when others =>
         return True;  -- never crash the timer
   end On_Timer;

   -- ── Vault init ────────────────────────────────────────────

   procedure Init_Vault is
      OK : Boolean;
   begin
      Exchange_Manager.Init (OK);
      if OK then
         Ada.Text_IO.Put_Line ("Vault: initialized OK");
      else
         Ada.Text_IO.Put_Line ("Vault: starting with empty vault");
      end if;
   end Init_Vault;

   -- ── Quit callback ─────────────────────────────────────────

   procedure On_Destroy
     (Self : access Gtk.Widget.Gtk_Widget_Record'Class)
   is
      pragma Unreferenced (Self);
   begin
      Gtk.Main.Main_Quit;
   end On_Destroy;

begin
   Ada.Text_IO.Put_Line ("========================================");
   Ada.Text_IO.Put_Line ("  OmniBus Ada GtkAda GUI v1.0");
   Ada.Text_IO.Put_Line ("  Native Desktop -- SPARK Verified Vault");
   Ada.Text_IO.Put_Line ("========================================");
   Ada.Text_IO.New_Line;

   Parse_Args;

   -- Initialize GTK
   Gtk.Main.Init;

   -- Apply dark theme
   Apply_Theme;

   -- Initialize vault (DPAPI encrypted exchange keys)
   Init_Vault;

   Ada.Text_IO.Put_Line ("RPC target: " &
      "localhost:" & Positive'Image (RPC_Client.Default_Port));
   Ada.Text_IO.Put_Line ("Vault mode: " &
      (if Current_Mode = Mode_Service
       then "Service (Named Pipe)"
       else "Embedded (DPAPI)"));
   Ada.Text_IO.New_Line;

   -- Show welcome dialog
   declare
      Choice : constant Welcome_Dialog.User_Choice := Welcome_Dialog.Run;
   begin
      case Choice is
         when Welcome_Dialog.Create_Wallet =>
            Ada.Text_IO.Put_Line ("User chose: Create New Wallet");
         when Welcome_Dialog.Import_Wallet =>
            Ada.Text_IO.Put_Line ("User chose: Import Wallet");
         when Welcome_Dialog.Connect_Node =>
            Ada.Text_IO.Put_Line ("User chose: Connect to Node");
         when Welcome_Dialog.No_Choice =>
            Ada.Text_IO.Put_Line ("User closed welcome dialog. Exiting.");
            return;
      end case;
   end;

   -- Create main window
   Main_Window.Create (Win);

   -- Connect destroy signal: window close -> quit GTK main loop
   Win.Window.On_Destroy (On_Destroy'Unrestricted_Access);

   -- Connect all button signal handlers
   Main_Window.Connect_Signals (Win'Unchecked_Access);

   -- Initial data populate (don't wait for timer)
   Main_Window.Refresh_All (Win);

   -- Start 5-second refresh timer
   Timer_ID := Timer_Cb.Timeout_Add (5_000, On_Timer'Access, True);

   -- Show window
   Main_Window.Show (Win);

   Ada.Text_IO.Put_Line ("GUI running. Close window to exit.");
   Ada.Text_IO.New_Line;

   -- Enter GTK main loop (blocking)
   Gtk.Main.Main;

   Ada.Text_IO.Put_Line ("Goodbye.");

exception
   when others =>
      Ada.Text_IO.Put_Line ("Fatal error in GUI -- exiting.");
      Gtk.Main.Main_Quit;
end Omnibus_Gtk_Main;

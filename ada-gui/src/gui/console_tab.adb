-- ============================================================
--  Console_Tab body  --  RPC console
-- ============================================================

pragma Ada_2022;

with Gtk.Enums;           use Gtk.Enums;
with Gtk.Widget; use Gtk.Widget;
with Gtk.Scrolled_Window;
with Gtk.Label;
with Gtk.Text_Iter;
with RPC_Client;

with GUI_Helpers;
package body Console_Tab is

   function Create return Console_Tab_Record is
      Tab : Console_Tab_Record;
      SW  : Gtk.Scrolled_Window.Gtk_Scrolled_Window;
      Lbl : Gtk.Label.Gtk_Label;
      Row : Gtk.Box.Gtk_Box;
   begin
      Gtk.Box.Gtk_New_Vbox (Tab.Root, Spacing => 8);
      Tab.Root.Set_Margin_Start (20);
      Tab.Root.Set_Margin_End (20);
      Tab.Root.Set_Margin_Top (16);
      Tab.Root.Set_Margin_Bottom (16);

      -- Title
      Gtk.Label.Gtk_New (Lbl, "RPC Console");
      GUI_Helpers.Add_Class (Lbl, "title");
      Lbl.Set_Halign (Align_Start);
      Tab.Root.Pack_Start (Lbl, Expand => False);

      -- Help text
      Gtk.Label.Gtk_New (Lbl,
         "Type a JSON-RPC command (e.g. getblockcount, " &
         "getnetworkinfo, getmempoolinfo, getpeerinfo)");
      GUI_Helpers.Add_Class (Lbl, "dim");
      Lbl.Set_Halign (Align_Start);
      Tab.Root.Pack_Start (Lbl, Expand => False);

      -- Output text view
      Gtk.Text_Buffer.Gtk_New (Tab.Output_Buf);
      Gtk.Text_View.Gtk_New (Tab.Output_View, Tab.Output_Buf);
      Tab.Output_View.Set_Editable (False);
      Tab.Output_View.Set_Cursor_Visible (False);
      Tab.Output_View.Set_Left_Margin (12);
      Tab.Output_View.Set_Right_Margin (12);
      Tab.Output_View.Set_Top_Margin (8);
      Tab.Output_View.Set_Bottom_Margin (8);

      Gtk.Scrolled_Window.Gtk_New (SW);
      SW.Set_Policy (Policy_Automatic, Policy_Automatic);
      SW.Add (Tab.Output_View);
      Tab.Root.Pack_Start (SW, Expand => True);

      -- Input row
      Gtk.Box.Gtk_New_Hbox (Row, Spacing => 8);

      Gtk.Label.Gtk_New (Lbl, ">");
      GUI_Helpers.Add_Class (Lbl, "teal");
      Row.Pack_Start (Lbl, Expand => False);

      Gtk.GEntry.Gtk_New (Tab.Input_Entry);
      Tab.Input_Entry.Set_Placeholder_Text ("Enter RPC command...");
      Row.Pack_Start (Tab.Input_Entry, Expand => True);

      Tab.Root.Pack_Start (Row, Expand => False);

      -- Welcome message
      Append_Output (Tab,
         "OmniBus RPC Console v1.0" & ASCII.LF &
         "Connected to localhost:8332" & ASCII.LF &
         "Type 'help' for available commands." & ASCII.LF &
         "----------------------------------------" & ASCII.LF);

      return Tab;
   end Create;

   procedure Append_Output
     (Tab  : in out Console_Tab_Record;
      Text : String)
   is
      Iter : Gtk.Text_Iter.Gtk_Text_Iter;
   begin
      Tab.Output_Buf.Get_End_Iter (Iter);
      Tab.Output_Buf.Insert (Iter, Text & ASCII.LF);
   end Append_Output;

   procedure Execute_Input (Tab : in out Console_Tab_Record) is
      Command : constant String := Tab.Input_Entry.Get_Text;
      R       : RPC_Client.RPC_Result;
   begin
      if Command'Length = 0 then
         return;
      end if;

      -- Add to history
      if Tab.Hist_Len < Max_History then
         Tab.Hist_Len := Tab.Hist_Len + 1;
      end if;
      declare
         Idx : constant Natural := Tab.Hist_Len;
         Len : constant Natural :=
            Natural'Min (Command'Length, 256);
      begin
         Tab.History (Idx) := (others => ' ');
         Tab.History (Idx) (1 .. Len) :=
            Command (Command'First .. Command'First + Len - 1);
      end;
      Tab.Hist_Pos := Tab.Hist_Len;

      Append_Output (Tab, "> " & Command);

      -- Execute
      if Command = "help" then
         Append_Output (Tab,
            "Available commands:" & ASCII.LF &
            "  getblockcount     - Current block height" & ASCII.LF &
            "  getnetworkinfo    - Network information" & ASCII.LF &
            "  getmempoolinfo    - Mempool statistics" & ASCII.LF &
            "  getpeerinfo       - Connected peers" & ASCII.LF &
            "  getmininginfo     - Mining information" & ASCII.LF &
            "  getblock <height> - Block by height" & ASCII.LF &
            "  help              - Show this help");
      elsif Command = "clear" then
         Tab.Output_Buf.Set_Text ("");
      else
         RPC_Client.Execute_Command (Command, R);
         if R.Success then
            Append_Output (Tab, R.Data (1 .. R.Len));
         else
            Append_Output (Tab,
               "Error: Could not connect to node at localhost:8332");
         end if;
      end if;

      Tab.Input_Entry.Set_Text ("");
   end Execute_Input;

   function Get_Widget (Tab : Console_Tab_Record)
      return Gtk.Widget.Gtk_Widget
   is
   begin
      return Gtk.Widget.Gtk_Widget (Tab.Root);
   end Get_Widget;

end Console_Tab;

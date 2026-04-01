-- ============================================================
--  Console_Tab  --  RPC console with command input + output
-- ============================================================

pragma Ada_2022;

with Gtk.Widget;
with Gtk.Box;
with Gtk.GEntry;
with Gtk.Text_View;
with Gtk.Text_Buffer;

package Console_Tab
   with SPARK_Mode => Off
is

   Max_History : constant := 100;

   type History_Array is array (1 .. Max_History) of String (1 .. 256);

   type Console_Tab_Record is record
      Root        : Gtk.Box.Gtk_Box;
      Output_View : Gtk.Text_View.Gtk_Text_View;
      Output_Buf  : Gtk.Text_Buffer.Gtk_Text_Buffer;
      Input_Entry : Gtk.GEntry.Gtk_Entry;
      History     : History_Array := (others => (others => ' '));
      Hist_Len    : Natural := 0;
      Hist_Pos    : Natural := 0;
   end record;

   function Create return Console_Tab_Record;

   procedure Append_Output
     (Tab  : in out Console_Tab_Record;
      Text : String);

   procedure Execute_Input (Tab : in out Console_Tab_Record);

   function Get_Widget (Tab : Console_Tab_Record)
      return Gtk.Widget.Gtk_Widget;

end Console_Tab;

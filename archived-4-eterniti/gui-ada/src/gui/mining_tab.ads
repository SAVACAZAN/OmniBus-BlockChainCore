-- ============================================================
--  Mining_Tab  --  Mining stats + miner table
-- ============================================================

pragma Ada_2022;

with Gtk.Widget;
with Gtk.Box;
with Gtk.Label;
with Gtk.Tree_View;
with Gtk.List_Store;

package Mining_Tab
   with SPARK_Mode => Off
is

   type Mining_Tab_Record is record
      Root           : Gtk.Box.Gtk_Box;
      Total_Miners   : Gtk.Label.Gtk_Label;
      Pool_Hash      : Gtk.Label.Gtk_Label;
      Block_Reward   : Gtk.Label.Gtk_Label;
      Your_Blocks    : Gtk.Label.Gtk_Label;
      Miner_View     : Gtk.Tree_View.Gtk_Tree_View;
      Miner_Store    : Gtk.List_Store.Gtk_List_Store;
   end record;

   function Create return Mining_Tab_Record;

   procedure Refresh (Tab : in out Mining_Tab_Record);

   function Get_Widget (Tab : Mining_Tab_Record)
      return Gtk.Widget.Gtk_Widget;

end Mining_Tab;

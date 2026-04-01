-- ============================================================
--  Block_Explorer_Tab  --  Block search + details
-- ============================================================

pragma Ada_2022;

with Gtk.Widget;
with Gtk.Box;
with Gtk.Label;
with Gtk.GEntry;
with Gtk.Button;
with Gtk.Tree_View;
with Gtk.List_Store;

package Block_Explorer_Tab
   with SPARK_Mode => Off
is

   type Block_Explorer_Tab_Record is record
      Root         : Gtk.Box.Gtk_Box;
      Search_Entry : Gtk.GEntry.Gtk_Entry;
      Search_Btn   : Gtk.Button.Gtk_Button;
      Block_View   : Gtk.Tree_View.Gtk_Tree_View;
      Block_Store  : Gtk.List_Store.Gtk_List_Store;
      Detail_Label : Gtk.Label.Gtk_Label;
   end record;

   function Create return Block_Explorer_Tab_Record;

   procedure Refresh (Tab : in out Block_Explorer_Tab_Record);

   function Get_Widget (Tab : Block_Explorer_Tab_Record)
      return Gtk.Widget.Gtk_Widget;

end Block_Explorer_Tab;

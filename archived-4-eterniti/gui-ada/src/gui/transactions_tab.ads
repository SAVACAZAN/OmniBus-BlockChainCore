-- ============================================================
--  Transactions_Tab  --  Transaction history table
-- ============================================================

pragma Ada_2022;

with Gtk.Widget;
with Gtk.Box;
with Gtk.Label;
with Gtk.Tree_View;
with Gtk.List_Store;
with Gtk.Button;
with Gtk.Combo_Box_Text;

package Transactions_Tab
   with SPARK_Mode => Off
is

   type Transactions_Tab_Record is record
      Root       : Gtk.Box.Gtk_Box;
      Tree       : Gtk.Tree_View.Gtk_Tree_View;
      Store      : Gtk.List_Store.Gtk_List_Store;
      Filter_Box : Gtk.Combo_Box_Text.Gtk_Combo_Box_Text;
      Count_Lbl  : Gtk.Label.Gtk_Label;
      Refresh_Btn: Gtk.Button.Gtk_Button;
   end record;

   function Create return Transactions_Tab_Record;

   procedure Refresh (Tab : in out Transactions_Tab_Record);

   function Get_Widget (Tab : Transactions_Tab_Record)
      return Gtk.Widget.Gtk_Widget;

end Transactions_Tab;

-- ============================================================
--  Overview_Tab  --  Dashboard: balance, blocks, mempool, peers
-- ============================================================

pragma Ada_2022;

with Gtk.Widget;
with Gtk.Box;
with Gtk.Label;
with Gtk.Progress_Bar;
with Gtk.Tree_View;
with Gtk.List_Store;

package Overview_Tab
   with SPARK_Mode => Off
is

   type Overview_Tab_Record is record
      Root          : Gtk.Box.Gtk_Box;
      Balance_Label : Gtk.Label.Gtk_Label;
      Balance_Sat   : Gtk.Label.Gtk_Label;
      Address_Label : Gtk.Label.Gtk_Label;
      Height_Label  : Gtk.Label.Gtk_Label;
      Difficulty    : Gtk.Label.Gtk_Label;
      Mempool_Label : Gtk.Label.Gtk_Label;
      Peer_Count    : Gtk.Label.Gtk_Label;
      Node_Status   : Gtk.Label.Gtk_Label;
      Sync_Bar      : Gtk.Progress_Bar.Gtk_Progress_Bar;
      Block_View    : Gtk.Tree_View.Gtk_Tree_View;
      Block_Store   : Gtk.List_Store.Gtk_List_Store;
      Mempool_View  : Gtk.Tree_View.Gtk_Tree_View;
      Mempool_Store : Gtk.List_Store.Gtk_List_Store;
   end record;

   function Create return Overview_Tab_Record;

   procedure Refresh (Tab : in out Overview_Tab_Record);

   function Get_Widget (Tab : Overview_Tab_Record)
      return Gtk.Widget.Gtk_Widget;

end Overview_Tab;

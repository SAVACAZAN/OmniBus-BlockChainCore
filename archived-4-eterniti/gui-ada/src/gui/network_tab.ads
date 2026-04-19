-- ============================================================
--  Network_Tab  --  Peer table + node info panel
-- ============================================================

pragma Ada_2022;

with Gtk.Widget;
with Gtk.Box;
with Gtk.Label;
with Gtk.Tree_View;
with Gtk.List_Store;

package Network_Tab
   with SPARK_Mode => Off
is

   type Network_Tab_Record is record
      Root        : Gtk.Box.Gtk_Box;
      Node_ID_Lbl : Gtk.Label.Gtk_Label;
      Version_Lbl : Gtk.Label.Gtk_Label;
      Uptime_Lbl  : Gtk.Label.Gtk_Label;
      Proto_Lbl   : Gtk.Label.Gtk_Label;
      Peer_View   : Gtk.Tree_View.Gtk_Tree_View;
      Peer_Store  : Gtk.List_Store.Gtk_List_Store;
   end record;

   function Create return Network_Tab_Record;

   procedure Refresh (Tab : in out Network_Tab_Record);

   function Get_Widget (Tab : Network_Tab_Record)
      return Gtk.Widget.Gtk_Widget;

end Network_Tab;

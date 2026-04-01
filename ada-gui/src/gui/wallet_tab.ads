-- ============================================================
--  Wallet_Tab  --  Multi-wallet tree: wallets -> accounts -> addresses
-- ============================================================

pragma Ada_2022;

with Gtk.Widget;
with Gtk.Box;
with Gtk.Label;
with Gtk.Tree_View;
with Gtk.Tree_Store;
with Gtk.Button;

package Wallet_Tab
   with SPARK_Mode => Off
is

   type Wallet_Tab_Record is record
      Root          : Gtk.Box.Gtk_Box;
      Tree          : Gtk.Tree_View.Gtk_Tree_View;
      Store         : Gtk.Tree_Store.Gtk_Tree_Store;
      Summary_Label : Gtk.Label.Gtk_Label;
      Detail_Label  : Gtk.Label.Gtk_Label;
      Regen_Btn     : Gtk.Button.Gtk_Button;
      Copy_Btn      : Gtk.Button.Gtk_Button;
   end record;

   function Create return Wallet_Tab_Record;

   procedure Refresh (Tab : in out Wallet_Tab_Record);

   function Get_Widget (Tab : Wallet_Tab_Record)
      return Gtk.Widget.Gtk_Widget;

end Wallet_Tab;

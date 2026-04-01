-- ============================================================
--  Exchange_Keys_Tab  --  Multi-exchange API key manager (GtkAda)
--
--  Sub-notebook: LCX | Kraken | Coinbase
--  Reuses existing Exchange_Manager + Vault_Types + Vault_Storage
-- ============================================================

pragma Ada_2022;

with Gtk.Widget;
with Gtk.Box;
with Gtk.Label;
with Gtk.Notebook;
with Gtk.Button;
with Gtk.Tree_View;
with Gtk.List_Store;
with Vault_Types;

package Exchange_Keys_Tab
   with SPARK_Mode => Off
is

   type Exchange_Panel_Record is record
      Root       : Gtk.Box.Gtk_Box;
      Tree       : Gtk.Tree_View.Gtk_Tree_View;
      Store      : Gtk.List_Store.Gtk_List_Store;
      Add_Btn    : Gtk.Button.Gtk_Button;
      Edit_Btn   : Gtk.Button.Gtk_Button;
      Delete_Btn : Gtk.Button.Gtk_Button;
      Count_Lbl  : Gtk.Label.Gtk_Label;
      Exchange   : Vault_Types.Exchange_Id;
   end record;

   type Panel_Array is array (Vault_Types.Exchange_Id) of Exchange_Panel_Record;

   type Exchange_Keys_Tab_Record is record
      Root        : Gtk.Box.Gtk_Box;
      Sub_Tabs    : Gtk.Notebook.Gtk_Notebook;
      Panels      : Panel_Array;
      Lock_Btn    : Gtk.Button.Gtk_Button;
      Status_Lbl  : Gtk.Label.Gtk_Label;
      Vault_Path  : Gtk.Label.Gtk_Label;
   end record;

   function Create return Exchange_Keys_Tab_Record;

   procedure Refresh_All (Tab : in out Exchange_Keys_Tab_Record);

   procedure Refresh_Panel (Panel : in out Exchange_Panel_Record);

   function Get_Widget (Tab : Exchange_Keys_Tab_Record)
      return Gtk.Widget.Gtk_Widget;

end Exchange_Keys_Tab;

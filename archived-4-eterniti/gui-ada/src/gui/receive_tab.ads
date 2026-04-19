-- ============================================================
--  Receive_Tab  --  Address display for receiving OMNI
-- ============================================================

pragma Ada_2022;

with Gtk.Widget;
with Gtk.Box;
with Gtk.Label;
with Gtk.Button;

package Receive_Tab
   with SPARK_Mode => Off
is

   type Receive_Tab_Record is record
      Root         : Gtk.Box.Gtk_Box;
      Address_Lbl  : Gtk.Label.Gtk_Label;
      Info_Lbl     : Gtk.Label.Gtk_Label;
      Copy_Btn     : Gtk.Button.Gtk_Button;
      New_Addr_Btn : Gtk.Button.Gtk_Button;
   end record;

   function Create return Receive_Tab_Record;

   procedure Set_Address (Tab : in out Receive_Tab_Record; Addr : String);

   function Get_Widget (Tab : Receive_Tab_Record)
      return Gtk.Widget.Gtk_Widget;

end Receive_Tab;

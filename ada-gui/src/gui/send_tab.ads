-- ============================================================
--  Send_Tab  --  Send OMNI transaction form
-- ============================================================

pragma Ada_2022;

with Gtk.Widget;
with Gtk.Box;
with Gtk.Label;
with Gtk.GEntry;
with Gtk.Spin_Button;
with Gtk.Button;

package Send_Tab
   with SPARK_Mode => Off
is

   type Send_Tab_Record is record
      Root           : Gtk.Box.Gtk_Box;
      Recipient_Edit : Gtk.GEntry.Gtk_Entry;
      Amount_Spin    : Gtk.Spin_Button.Gtk_Spin_Button;
      Fee_Label      : Gtk.Label.Gtk_Label;
      Balance_Label  : Gtk.Label.Gtk_Label;
      Status_Label   : Gtk.Label.Gtk_Label;
      Send_Btn       : Gtk.Button.Gtk_Button;
   end record;

   function Create return Send_Tab_Record;

   procedure Refresh (Tab : in out Send_Tab_Record);

   function Get_Widget (Tab : Send_Tab_Record)
      return Gtk.Widget.Gtk_Widget;

end Send_Tab;

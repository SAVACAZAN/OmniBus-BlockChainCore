-- ============================================================
--  GUI_Helpers  --  Convenience wrappers for GtkAda
-- ============================================================

pragma Ada_2022;

with Gtk.Widget;

package GUI_Helpers
   with SPARK_Mode => Off
is

   -- Add a CSS class to any widget
   procedure Add_Class
     (W     : not null access Gtk.Widget.Gtk_Widget_Record'Class;
      Class : String);

   -- Remove a CSS class from any widget
   procedure Remove_Class
     (W     : not null access Gtk.Widget.Gtk_Widget_Record'Class;
      Class : String);

end GUI_Helpers;

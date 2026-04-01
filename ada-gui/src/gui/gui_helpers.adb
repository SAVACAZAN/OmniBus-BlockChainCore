-- ============================================================
--  GUI_Helpers body
-- ============================================================

pragma Ada_2022;

with Gtk.Style_Context;

package body GUI_Helpers is

   procedure Add_Class
     (W     : not null access Gtk.Widget.Gtk_Widget_Record'Class;
      Class : String)
   is
      Ctx : constant Gtk.Style_Context.Gtk_Style_Context :=
         Gtk.Style_Context.Get_Style_Context (W);
   begin
      Ctx.Add_Class (Class);
   end Add_Class;

   procedure Remove_Class
     (W     : not null access Gtk.Widget.Gtk_Widget_Record'Class;
      Class : String)
   is
      Ctx : constant Gtk.Style_Context.Gtk_Style_Context :=
         Gtk.Style_Context.Get_Style_Context (W);
   begin
      Ctx.Remove_Class (Class);
   end Remove_Class;

end GUI_Helpers;

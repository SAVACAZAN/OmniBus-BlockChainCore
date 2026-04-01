-- ============================================================
--  Transactions_Tab body
-- ============================================================

pragma Ada_2022;

with Gtk.Enums;           use Gtk.Enums;
with Gtk.Widget; use Gtk.Widget;
with Gtk.Scrolled_Window;
with Gtk.Cell_Renderer_Text;
with Gtk.Tree_View_Column;
with Glib;                use Glib;

with GUI_Helpers;
package body Transactions_Tab is

   Col_TxID   : constant := 0;
   Col_From   : constant := 1;
   Col_To     : constant := 2;
   Col_Amount : constant := 3;
   Col_Fee    : constant := 4;
   Col_Block  : constant := 5;
   Col_Status : constant := 6;

   function Create return Transactions_Tab_Record is
      Tab  : Transactions_Tab_Record;
      SW   : Gtk.Scrolled_Window.Gtk_Scrolled_Window;
      HBox : Gtk.Box.Gtk_Box;
      Lbl  : Gtk.Label.Gtk_Label;
   begin
      Gtk.Box.Gtk_New_Vbox (Tab.Root, Spacing => 12);
      Tab.Root.Set_Margin_Start (20);
      Tab.Root.Set_Margin_End (20);
      Tab.Root.Set_Margin_Top (16);
      Tab.Root.Set_Margin_Bottom (16);

      -- Header row
      Gtk.Box.Gtk_New_Hbox (HBox, Spacing => 10);

      Gtk.Label.Gtk_New (Lbl, "Transactions");
      GUI_Helpers.Add_Class (Lbl, "title");
      HBox.Pack_Start (Lbl, Expand => False);

      -- Filter combo
      Gtk.Combo_Box_Text.Gtk_New (Tab.Filter_Box);
      Tab.Filter_Box.Append_Text ("All");
      Tab.Filter_Box.Append_Text ("Sent");
      Tab.Filter_Box.Append_Text ("Received");
      Tab.Filter_Box.Append_Text ("Pending");
      Tab.Filter_Box.Set_Active (0);
      HBox.Pack_End (Tab.Filter_Box, Expand => False);

      Gtk.Button.Gtk_New (Tab.Refresh_Btn, "Refresh");
      HBox.Pack_End (Tab.Refresh_Btn, Expand => False);

      Tab.Root.Pack_Start (HBox, Expand => False);

      -- Transaction count
      Gtk.Label.Gtk_New (Tab.Count_Lbl, "0 transactions");
      GUI_Helpers.Add_Class (Tab.Count_Lbl, "dim");
      Tab.Count_Lbl.Set_Halign (Align_Start);
      Tab.Root.Pack_Start (Tab.Count_Lbl, Expand => False);

      -- Table
      Gtk.List_Store.Gtk_New
        (Tab.Store,
         (Col_TxID   => GType_String,
          Col_From   => GType_String,
          Col_To     => GType_String,
          Col_Amount => GType_String,
          Col_Fee    => GType_String,
          Col_Block  => GType_String,
          Col_Status => GType_String));

      Gtk.Tree_View.Gtk_New (Tab.Tree, Tab.Store);
      Tab.Tree.Set_Headers_Visible (True);

      declare
         Ren : Gtk.Cell_Renderer_Text.Gtk_Cell_Renderer_Text;
         Col : Gtk.Tree_View_Column.Gtk_Tree_View_Column;
         Num : Gint;
         pragma Unreferenced (Num);
         Names : constant array (0 .. 6) of String (1 .. 6) :=
           ("TxID  ", "From  ", "To    ", "Amount", "Fee   ",
            "Block ", "Status");
      begin
         for I in 0 .. 6 loop
            Gtk.Cell_Renderer_Text.Gtk_New (Ren);
            Gtk.Tree_View_Column.Gtk_New (Col);
            Col.Set_Title (Names (I));
            Col.Pack_Start (Ren, Expand => True);
            Col.Add_Attribute (Ren, "text", Gint (I));
            Col.Set_Resizable (True);
            if I = 0 then
               Col.Set_Expand (True);
            end if;
            Num := Tab.Tree.Append_Column (Col);
         end loop;
      end;

      Gtk.Scrolled_Window.Gtk_New (SW);
      SW.Set_Policy (Policy_Automatic, Policy_Automatic);
      SW.Add (Tab.Tree);
      Tab.Root.Pack_Start (SW, Expand => True);

      return Tab;
   end Create;

   procedure Refresh (Tab : in out Transactions_Tab_Record) is
   begin
      -- Would call RPC_Client.Get_Transactions and populate store
      null;
   end Refresh;

   function Get_Widget (Tab : Transactions_Tab_Record)
      return Gtk.Widget.Gtk_Widget
   is
   begin
      return Gtk.Widget.Gtk_Widget (Tab.Root);
   end Get_Widget;

end Transactions_Tab;

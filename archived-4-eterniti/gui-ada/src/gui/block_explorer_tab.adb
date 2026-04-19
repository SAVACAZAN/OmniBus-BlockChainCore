-- ============================================================
--  Block_Explorer_Tab body
-- ============================================================

pragma Ada_2022;

with Gtk.Enums;           use Gtk.Enums;
with Gtk.Widget; use Gtk.Widget;
with Gtk.Frame;
with Gtk.Scrolled_Window;
with Gtk.Cell_Renderer_Text;
with Gtk.Tree_View_Column;
with Gtk.Separator;
with Glib;                use Glib;

with GUI_Helpers;
package body Block_Explorer_Tab is

   Col_Height : constant := 0;
   Col_Hash   : constant := 1;
   Col_Txns   : constant := 2;
   Col_Size   : constant := 3;
   Col_Time   : constant := 4;
   Col_Miner  : constant := 5;

   function Create return Block_Explorer_Tab_Record is
      Tab  : Block_Explorer_Tab_Record;
      HBox : Gtk.Box.Gtk_Box;
      SW   : Gtk.Scrolled_Window.Gtk_Scrolled_Window;
      Sep  : Gtk.Separator.Gtk_Separator;
      Frame : Gtk.Frame.Gtk_Frame;
      Lbl  : Gtk.Label.Gtk_Label;
   begin
      Gtk.Box.Gtk_New_Vbox (Tab.Root, Spacing => 12);
      Tab.Root.Set_Margin_Start (20);
      Tab.Root.Set_Margin_End (20);
      Tab.Root.Set_Margin_Top (16);
      Tab.Root.Set_Margin_Bottom (16);

      -- Title
      Gtk.Label.Gtk_New (Lbl, "Block Explorer");
      GUI_Helpers.Add_Class (Lbl, "title");
      Lbl.Set_Halign (Align_Start);
      Tab.Root.Pack_Start (Lbl, Expand => False);

      -- Search bar
      Gtk.Box.Gtk_New_Hbox (HBox, Spacing => 8);

      Gtk.GEntry.Gtk_New (Tab.Search_Entry);
      Tab.Search_Entry.Set_Placeholder_Text
        ("Search by block height or hash...");
      HBox.Pack_Start (Tab.Search_Entry, Expand => True);

      Gtk.Button.Gtk_New (Tab.Search_Btn, "Search");
      GUI_Helpers.Add_Class (Tab.Search_Btn, "accent");
      HBox.Pack_End (Tab.Search_Btn, Expand => False);

      Tab.Root.Pack_Start (HBox, Expand => False);

      -- Block table
      Gtk.List_Store.Gtk_New
        (Tab.Block_Store,
         (Col_Height => GType_String,
          Col_Hash   => GType_String,
          Col_Txns   => GType_String,
          Col_Size   => GType_String,
          Col_Time   => GType_String,
          Col_Miner  => GType_String));

      Gtk.Tree_View.Gtk_New (Tab.Block_View, Tab.Block_Store);
      Tab.Block_View.Set_Headers_Visible (True);

      declare
         Ren : Gtk.Cell_Renderer_Text.Gtk_Cell_Renderer_Text;
         Col : Gtk.Tree_View_Column.Gtk_Tree_View_Column;
         Num : Gint;
         pragma Unreferenced (Num);
      begin
         for I in 0 .. 5 loop
            Gtk.Cell_Renderer_Text.Gtk_New (Ren);
            Gtk.Tree_View_Column.Gtk_New (Col);
            Col.Set_Title
              ((case I is
                  when 0 => "Height",
                  when 1 => "Hash",
                  when 2 => "Txns",
                  when 3 => "Size",
                  when 4 => "Time",
                  when others => "Miner"));
            Col.Pack_Start (Ren, Expand => True);
            Col.Add_Attribute (Ren, "text", Gint (I));
            Col.Set_Resizable (True);
            if I = 1 then
               Col.Set_Expand (True);
            end if;
            Num := Tab.Block_View.Append_Column (Col);
         end loop;
      end;

      Gtk.Scrolled_Window.Gtk_New (SW);
      SW.Set_Policy (Policy_Automatic, Policy_Automatic);
      SW.Add (Tab.Block_View);
      Tab.Root.Pack_Start (SW, Expand => True);

      -- Separator
      Gtk.Separator.Gtk_New_Hseparator (Sep);
      Tab.Root.Pack_Start (Sep, Expand => False);

      -- Block detail panel
      Gtk.Frame.Gtk_New (Frame);
      GUI_Helpers.Add_Class (Frame, "stat-card");

      Gtk.Label.Gtk_New (Tab.Detail_Label,
         "Select a block to view details");
      GUI_Helpers.Add_Class (Tab.Detail_Label, "dim");
      Tab.Detail_Label.Set_Halign (Align_Start);
      Tab.Detail_Label.Set_Line_Wrap (True);
      Tab.Detail_Label.Set_Margin_Start (16);
      Tab.Detail_Label.Set_Margin_End (16);
      Tab.Detail_Label.Set_Margin_Top (12);
      Tab.Detail_Label.Set_Margin_Bottom (12);

      Frame.Add (Tab.Detail_Label);
      Tab.Root.Pack_Start (Frame, Expand => False);

      return Tab;
   end Create;

   procedure Refresh (Tab : in out Block_Explorer_Tab_Record) is
   begin
      -- Would call RPC_Client.Get_Block for latest blocks
      null;
   end Refresh;

   function Get_Widget (Tab : Block_Explorer_Tab_Record)
      return Gtk.Widget.Gtk_Widget
   is
   begin
      return Gtk.Widget.Gtk_Widget (Tab.Root);
   end Get_Widget;

end Block_Explorer_Tab;

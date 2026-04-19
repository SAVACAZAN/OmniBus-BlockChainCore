-- ============================================================
--  Mining_Tab body
-- ============================================================

pragma Ada_2022;

with Gtk.Enums;           use Gtk.Enums;
with Gtk.Widget; use Gtk.Widget;
with Gtk.Frame;
with Gtk.Grid;
with Gtk.Scrolled_Window;
with Gtk.Cell_Renderer_Text;
with Gtk.Tree_View_Column;
with Glib;                use Glib;

with GUI_Helpers;
package body Mining_Tab is

   Col_MinerID  : constant := 0;
   Col_Hashrate : constant := 1;
   Col_Shares   : constant := 2;
   Col_Last_Blk : constant := 3;

   function Make_Card
     (Title : String; Value_Lbl : access Gtk.Label.Gtk_Label_Record'Class)
      return Gtk.Frame.Gtk_Frame
   is
      Frame : Gtk.Frame.Gtk_Frame;
      Box   : Gtk.Box.Gtk_Box;
      Lbl   : Gtk.Label.Gtk_Label;
   begin
      Gtk.Frame.Gtk_New (Frame);
      GUI_Helpers.Add_Class (Frame, "stat-card");

      Gtk.Box.Gtk_New_Vbox (Box, Spacing => 4);
      Box.Set_Margin_Start (12);
      Box.Set_Margin_End (12);
      Box.Set_Margin_Top (8);
      Box.Set_Margin_Bottom (8);

      Gtk.Label.Gtk_New (Lbl, Title);
      GUI_Helpers.Add_Class (Lbl, "stat-label");
      Lbl.Set_Halign (Align_Start);
      Box.Pack_Start (Lbl, Expand => False);

      GUI_Helpers.Add_Class (Value_Lbl, "stat-value");
      Value_Lbl.Set_Halign (Align_Start);
      Box.Pack_Start (Gtk.Label.Gtk_Label (Value_Lbl), Expand => False);

      Frame.Add (Box);
      return Frame;
   end Make_Card;

   function Create return Mining_Tab_Record is
      Tab  : Mining_Tab_Record;
      Grid : Gtk.Grid.Gtk_Grid;
      SW   : Gtk.Scrolled_Window.Gtk_Scrolled_Window;
      Lbl  : Gtk.Label.Gtk_Label;
   begin
      Gtk.Box.Gtk_New_Vbox (Tab.Root, Spacing => 12);
      Tab.Root.Set_Margin_Start (20);
      Tab.Root.Set_Margin_End (20);
      Tab.Root.Set_Margin_Top (16);
      Tab.Root.Set_Margin_Bottom (16);

      -- Title
      Gtk.Label.Gtk_New (Lbl, "Mining");
      GUI_Helpers.Add_Class (Lbl, "title");
      Lbl.Set_Halign (Align_Start);
      Tab.Root.Pack_Start (Lbl, Expand => False);

      -- Stats cards
      Gtk.Grid.Gtk_New (Grid);
      Grid.Set_Column_Spacing (12);
      Grid.Set_Column_Homogeneous (True);

      Gtk.Label.Gtk_New (Tab.Total_Miners, "0");
      Grid.Attach (Make_Card ("TOTAL MINERS", Tab.Total_Miners), 0, 0);

      Gtk.Label.Gtk_New (Tab.Pool_Hash, "0 H/s");
      Grid.Attach (Make_Card ("POOL HASHRATE", Tab.Pool_Hash), 1, 0);

      Gtk.Label.Gtk_New (Tab.Block_Reward, "50 OMNI");
      Grid.Attach (Make_Card ("BLOCK REWARD", Tab.Block_Reward), 2, 0);

      Gtk.Label.Gtk_New (Tab.Your_Blocks, "0");
      Grid.Attach (Make_Card ("YOUR BLOCKS", Tab.Your_Blocks), 3, 0);

      Tab.Root.Pack_Start (Grid, Expand => False);

      -- Miner table
      Gtk.Label.Gtk_New (Lbl, "Connected Miners");
      GUI_Helpers.Add_Class (Lbl, "title");
      Lbl.Set_Halign (Align_Start);
      Tab.Root.Pack_Start (Lbl, Expand => False);

      Gtk.List_Store.Gtk_New
        (Tab.Miner_Store,
         (Col_MinerID  => GType_String,
          Col_Hashrate => GType_String,
          Col_Shares   => GType_String,
          Col_Last_Blk => GType_String));

      Gtk.Tree_View.Gtk_New (Tab.Miner_View, Tab.Miner_Store);
      Tab.Miner_View.Set_Headers_Visible (True);

      declare
         Ren : Gtk.Cell_Renderer_Text.Gtk_Cell_Renderer_Text;
         Col : Gtk.Tree_View_Column.Gtk_Tree_View_Column;
         Num : Gint;
         pragma Unreferenced (Num);
      begin
         for I in 0 .. 3 loop
            Gtk.Cell_Renderer_Text.Gtk_New (Ren);
            Gtk.Tree_View_Column.Gtk_New (Col);
            Col.Set_Title
              ((case I is
                  when 0 => "Miner ID",
                  when 1 => "Hashrate",
                  when 2 => "Shares",
                  when others => "Last Block"));
            Col.Pack_Start (Ren, Expand => True);
            Col.Add_Attribute (Ren, "text", Gint (I));
            Col.Set_Resizable (True);
            Num := Tab.Miner_View.Append_Column (Col);
         end loop;
      end;

      Gtk.Scrolled_Window.Gtk_New (SW);
      SW.Set_Policy (Policy_Automatic, Policy_Automatic);
      SW.Add (Tab.Miner_View);
      Tab.Root.Pack_Start (SW, Expand => True);

      return Tab;
   end Create;

   procedure Refresh (Tab : in out Mining_Tab_Record) is
   begin
      -- Would call RPC_Client.Get_Mining_Info
      null;
   end Refresh;

   function Get_Widget (Tab : Mining_Tab_Record)
      return Gtk.Widget.Gtk_Widget
   is
   begin
      return Gtk.Widget.Gtk_Widget (Tab.Root);
   end Get_Widget;

end Mining_Tab;

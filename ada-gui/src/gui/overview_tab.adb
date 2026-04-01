-- ============================================================
--  Overview_Tab body  --  Dashboard layout + RPC refresh
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
with Glib.Values;
with Gtk.Tree_Model;
with RPC_Client;

with GUI_Helpers;
package body Overview_Tab is

   -- Column indices for blocks tree
   Col_Height : constant := 0;
   Col_Hash   : constant := 1;
   Col_Txns   : constant := 2;
   Col_Time   : constant := 3;

   -- Column indices for mempool tree
   Col_TxID   : constant := 0;
   Col_From   : constant := 1;
   Col_Amount : constant := 2;
   Col_Fee    : constant := 3;

   -- ── Helper: create a stat card ────────────────────────────

   function Make_Stat_Card
     (Title     : String;
      Value_Lbl : access Gtk.Label.Gtk_Label_Record'Class)
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
   end Make_Stat_Card;

   -- ── Create ────────────────────────────────────────────────

   function Create return Overview_Tab_Record is
      Tab  : Overview_Tab_Record;
      Grid : Gtk.Grid.Gtk_Grid;
      SW1  : Gtk.Scrolled_Window.Gtk_Scrolled_Window;
      SW2  : Gtk.Scrolled_Window.Gtk_Scrolled_Window;
      Lbl  : Gtk.Label.Gtk_Label;
   begin
      Gtk.Box.Gtk_New_Vbox (Tab.Root, Spacing => 12);
      Tab.Root.Set_Margin_Start (20);
      Tab.Root.Set_Margin_End (20);
      Tab.Root.Set_Margin_Top (16);
      Tab.Root.Set_Margin_Bottom (16);

      -- Title
      Gtk.Label.Gtk_New (Lbl, "Overview");
      GUI_Helpers.Add_Class (Lbl, "title");
      Lbl.Set_Halign (Align_Start);
      Tab.Root.Pack_Start (Lbl, Expand => False);

      -- Stats grid (2 rows x 4 cols)
      Gtk.Grid.Gtk_New (Grid);
      Grid.Set_Column_Spacing (12);
      Grid.Set_Row_Spacing (12);
      Grid.Set_Column_Homogeneous (True);

      -- Balance
      Gtk.Label.Gtk_New (Tab.Balance_Label, "0.000000000 OMNI");
      GUI_Helpers.Add_Class (Tab.Balance_Label, "balance");
      Grid.Attach (Make_Stat_Card ("BALANCE", Tab.Balance_Label), 0, 0);

      -- Balance SAT
      Gtk.Label.Gtk_New (Tab.Balance_Sat, "0 SAT");
      Grid.Attach (Make_Stat_Card ("SATOSHIS", Tab.Balance_Sat), 1, 0);

      -- Block Height
      Gtk.Label.Gtk_New (Tab.Height_Label, "0");
      Grid.Attach (Make_Stat_Card ("BLOCK HEIGHT", Tab.Height_Label), 2, 0);

      -- Difficulty
      Gtk.Label.Gtk_New (Tab.Difficulty, "0");
      Grid.Attach (Make_Stat_Card ("DIFFICULTY", Tab.Difficulty), 3, 0);

      -- Mempool
      Gtk.Label.Gtk_New (Tab.Mempool_Label, "0 txns");
      Grid.Attach (Make_Stat_Card ("MEMPOOL", Tab.Mempool_Label), 0, 1);

      -- Peers
      Gtk.Label.Gtk_New (Tab.Peer_Count, "0");
      Grid.Attach (Make_Stat_Card ("PEERS", Tab.Peer_Count), 1, 1);

      -- Node Status
      Gtk.Label.Gtk_New (Tab.Node_Status, "Offline");
      Grid.Attach (Make_Stat_Card ("NODE STATUS", Tab.Node_Status), 2, 1);

      -- Address
      Gtk.Label.Gtk_New (Tab.Address_Label, "ob1q...");
      GUI_Helpers.Add_Class (Tab.Address_Label, "mono");
      Grid.Attach (Make_Stat_Card ("YOUR ADDRESS", Tab.Address_Label), 3, 1);

      Tab.Root.Pack_Start (Grid, Expand => False);

      -- Sync progress
      Gtk.Progress_Bar.Gtk_New (Tab.Sync_Bar);
      Tab.Sync_Bar.Set_Fraction (0.0);
      Tab.Sync_Bar.Set_Show_Text (True);
      Tab.Sync_Bar.Set_Text ("Sync: connecting...");
      Tab.Root.Pack_Start (Tab.Sync_Bar, Expand => False);

      -- Recent Blocks table
      Gtk.Label.Gtk_New (Lbl, "Recent Blocks");
      GUI_Helpers.Add_Class (Lbl, "title");
      Lbl.Set_Halign (Align_Start);
      Tab.Root.Pack_Start (Lbl, Expand => False);

      Gtk.List_Store.Gtk_New
        (Tab.Block_Store,
         (Col_Height => GType_String,
          Col_Hash   => GType_String,
          Col_Txns   => GType_String,
          Col_Time   => GType_String));

      Gtk.Tree_View.Gtk_New (Tab.Block_View, Tab.Block_Store);
      Tab.Block_View.Set_Headers_Visible (True);

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
                  when 0 => "Height",
                  when 1 => "Hash",
                  when 2 => "Txns",
                  when others => "Time"));
            Col.Pack_Start (Ren, Expand => True);
            Col.Add_Attribute (Ren, "text", Gint (I));
            if I = 1 then
               Col.Set_Expand (True);
            end if;
            Num := Tab.Block_View.Append_Column (Col);
         end loop;
      end;

      Gtk.Scrolled_Window.Gtk_New (SW1);
      SW1.Set_Policy (Policy_Automatic, Policy_Automatic);
      SW1.Set_Min_Content_Height (180);
      SW1.Add (Tab.Block_View);
      Tab.Root.Pack_Start (SW1, Expand => True);

      -- Mempool table
      Gtk.Label.Gtk_New (Lbl, "Mempool");
      GUI_Helpers.Add_Class (Lbl, "title");
      Lbl.Set_Halign (Align_Start);
      Tab.Root.Pack_Start (Lbl, Expand => False);

      Gtk.List_Store.Gtk_New
        (Tab.Mempool_Store,
         (Col_TxID   => GType_String,
          Col_From   => GType_String,
          Col_Amount => GType_String,
          Col_Fee    => GType_String));

      Gtk.Tree_View.Gtk_New (Tab.Mempool_View, Tab.Mempool_Store);
      Tab.Mempool_View.Set_Headers_Visible (True);

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
                  when 0 => "TxID",
                  when 1 => "From",
                  when 2 => "Amount",
                  when others => "Fee"));
            Col.Pack_Start (Ren, Expand => True);
            Col.Add_Attribute (Ren, "text", Gint (I));
            if I = 0 then
               Col.Set_Expand (True);
            end if;
            Num := Tab.Mempool_View.Append_Column (Col);
         end loop;
      end;

      Gtk.Scrolled_Window.Gtk_New (SW2);
      SW2.Set_Policy (Policy_Automatic, Policy_Automatic);
      SW2.Set_Min_Content_Height (140);
      SW2.Add (Tab.Mempool_View);
      Tab.Root.Pack_Start (SW2, Expand => True);

      return Tab;
   end Create;

   -- ── Refresh via RPC ───────────────────────────────────────

   procedure Refresh (Tab : in out Overview_Tab_Record) is
      Height : Natural;
      OK     : Boolean;
   begin
      -- Single quick RPC call — if node is offline, bail fast
      RPC_Client.Get_Block_Height (Height, OK);
      if OK then
         Tab.Height_Label.Set_Text (Natural'Image (Height));
         Tab.Node_Status.Set_Text ("Online");
         Tab.Sync_Bar.Set_Fraction (1.0);
         Tab.Sync_Bar.Set_Text ("Synced — block" & Natural'Image (Height));
      else
         Tab.Node_Status.Set_Text ("Offline");
         Tab.Sync_Bar.Set_Fraction (0.0);
         Tab.Sync_Bar.Set_Text ("Node offline — start omnibus-node");
      end if;
   exception
      when others =>
         Tab.Node_Status.Set_Text ("Offline");
         Tab.Sync_Bar.Set_Text ("Node offline");
   end Refresh;

   -- ── Get widget ────────────────────────────────────────────

   function Get_Widget (Tab : Overview_Tab_Record)
      return Gtk.Widget.Gtk_Widget
   is
   begin
      return Gtk.Widget.Gtk_Widget (Tab.Root);
   end Get_Widget;

end Overview_Tab;

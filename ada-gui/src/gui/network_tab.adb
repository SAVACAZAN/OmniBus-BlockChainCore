-- ============================================================
--  Network_Tab body
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
package body Network_Tab is

   Col_PeerID  : constant := 0;
   Col_Address : constant := 1;
   Col_Latency : constant := 2;
   Col_Version : constant := 3;
   Col_Score   : constant := 4;

   function Make_Info_Row
     (Title : String; Value_Lbl : access Gtk.Label.Gtk_Label_Record'Class)
      return Gtk.Box.Gtk_Box
   is
      Row : Gtk.Box.Gtk_Box;
      Lbl : Gtk.Label.Gtk_Label;
   begin
      Gtk.Box.Gtk_New_Hbox (Row, Spacing => 10);

      Gtk.Label.Gtk_New (Lbl, Title & ":");
      GUI_Helpers.Add_Class (Lbl, "stat-label");
      Lbl.Set_Halign (Align_Start);
      Lbl.Set_Size_Request (120, -1);
      Row.Pack_Start (Lbl, Expand => False);

      GUI_Helpers.Add_Class (Value_Lbl, "mono");
      Value_Lbl.Set_Halign (Align_Start);
      Row.Pack_Start (Gtk.Label.Gtk_Label (Value_Lbl), Expand => True);

      return Row;
   end Make_Info_Row;

   function Create return Network_Tab_Record is
      Tab   : Network_Tab_Record;
      Frame : Gtk.Frame.Gtk_Frame;
      Inner : Gtk.Box.Gtk_Box;
      SW    : Gtk.Scrolled_Window.Gtk_Scrolled_Window;
      Lbl   : Gtk.Label.Gtk_Label;
   begin
      Gtk.Box.Gtk_New_Vbox (Tab.Root, Spacing => 12);
      Tab.Root.Set_Margin_Start (20);
      Tab.Root.Set_Margin_End (20);
      Tab.Root.Set_Margin_Top (16);
      Tab.Root.Set_Margin_Bottom (16);

      -- Title
      Gtk.Label.Gtk_New (Lbl, "Network");
      GUI_Helpers.Add_Class (Lbl, "title");
      Lbl.Set_Halign (Align_Start);
      Tab.Root.Pack_Start (Lbl, Expand => False);

      -- Node info panel
      Gtk.Frame.Gtk_New (Frame);
      GUI_Helpers.Add_Class (Frame, "stat-card");

      Gtk.Box.Gtk_New_Vbox (Inner, Spacing => 8);
      Inner.Set_Margin_Start (16);
      Inner.Set_Margin_End (16);
      Inner.Set_Margin_Top (12);
      Inner.Set_Margin_Bottom (12);

      Gtk.Label.Gtk_New (Tab.Node_ID_Lbl, "...");
      Inner.Pack_Start (Make_Info_Row ("Node ID", Tab.Node_ID_Lbl),
                        Expand => False);

      Gtk.Label.Gtk_New (Tab.Version_Lbl, "OmniBus v1.0.0");
      Inner.Pack_Start (Make_Info_Row ("Version", Tab.Version_Lbl),
                        Expand => False);

      Gtk.Label.Gtk_New (Tab.Uptime_Lbl, "0s");
      Inner.Pack_Start (Make_Info_Row ("Uptime", Tab.Uptime_Lbl),
                        Expand => False);

      Gtk.Label.Gtk_New (Tab.Proto_Lbl, "TCP + Kademlia DHT");
      Inner.Pack_Start (Make_Info_Row ("Protocol", Tab.Proto_Lbl),
                        Expand => False);

      Frame.Add (Inner);
      Tab.Root.Pack_Start (Frame, Expand => False);

      -- Peer table
      Gtk.Label.Gtk_New (Lbl, "Connected Peers");
      GUI_Helpers.Add_Class (Lbl, "title");
      Lbl.Set_Halign (Align_Start);
      Tab.Root.Pack_Start (Lbl, Expand => False);

      Gtk.List_Store.Gtk_New
        (Tab.Peer_Store,
         (Col_PeerID  => GType_String,
          Col_Address => GType_String,
          Col_Latency => GType_String,
          Col_Version => GType_String,
          Col_Score   => GType_String));

      Gtk.Tree_View.Gtk_New (Tab.Peer_View, Tab.Peer_Store);
      Tab.Peer_View.Set_Headers_Visible (True);

      declare
         Ren : Gtk.Cell_Renderer_Text.Gtk_Cell_Renderer_Text;
         Col : Gtk.Tree_View_Column.Gtk_Tree_View_Column;
         Num : Gint;
         pragma Unreferenced (Num);
      begin
         for I in 0 .. 4 loop
            Gtk.Cell_Renderer_Text.Gtk_New (Ren);
            Gtk.Tree_View_Column.Gtk_New (Col);
            Col.Set_Title
              ((case I is
                  when 0 => "Peer ID",
                  when 1 => "Address",
                  when 2 => "Latency",
                  when 3 => "Version",
                  when others => "Score"));
            Col.Pack_Start (Ren, Expand => True);
            Col.Add_Attribute (Ren, "text", Gint (I));
            Col.Set_Resizable (True);
            Num := Tab.Peer_View.Append_Column (Col);
         end loop;
      end;

      Gtk.Scrolled_Window.Gtk_New (SW);
      SW.Set_Policy (Policy_Automatic, Policy_Automatic);
      SW.Add (Tab.Peer_View);
      Tab.Root.Pack_Start (SW, Expand => True);

      return Tab;
   end Create;

   procedure Refresh (Tab : in out Network_Tab_Record) is
   begin
      -- Would call RPC_Client.Get_Peer_List / Get_Network_Info
      null;
   end Refresh;

   function Get_Widget (Tab : Network_Tab_Record)
      return Gtk.Widget.Gtk_Widget
   is
   begin
      return Gtk.Widget.Gtk_Widget (Tab.Root);
   end Get_Widget;

end Network_Tab;

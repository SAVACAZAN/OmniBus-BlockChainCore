-- ============================================================
--  Send_Tab body  --  Transaction send form
-- ============================================================

pragma Ada_2022;

with Gtk.Enums;           use Gtk.Enums;
with Gtk.Widget; use Gtk.Widget;
with Gtk.Frame;
with Gtk.Adjustment;
with Glib;                use Glib;
with RPC_Client;

with GUI_Helpers;
package body Send_Tab is

   function Create return Send_Tab_Record is
      Tab   : Send_Tab_Record;
      Frame : Gtk.Frame.Gtk_Frame;
      Inner : Gtk.Box.Gtk_Box;
      Row   : Gtk.Box.Gtk_Box;
      Lbl   : Gtk.Label.Gtk_Label;
      Adj   : Gtk.Adjustment.Gtk_Adjustment;
   begin
      Gtk.Box.Gtk_New_Vbox (Tab.Root, Spacing => 16);
      Tab.Root.Set_Margin_Start (20);
      Tab.Root.Set_Margin_End (20);
      Tab.Root.Set_Margin_Top (16);
      Tab.Root.Set_Margin_Bottom (16);

      -- Title
      Gtk.Label.Gtk_New (Lbl, "Send OMNI");
      GUI_Helpers.Add_Class (Lbl, "title");
      Lbl.Set_Halign (Align_Start);
      Tab.Root.Pack_Start (Lbl, Expand => False);

      -- Balance display
      Gtk.Label.Gtk_New (Tab.Balance_Label, "Balance: 0.000000000 OMNI");
      GUI_Helpers.Add_Class (Tab.Balance_Label, "teal");
      Tab.Balance_Label.Set_Halign (Align_Start);
      Tab.Root.Pack_Start (Tab.Balance_Label, Expand => False);

      -- Form card
      Gtk.Frame.Gtk_New (Frame);
      GUI_Helpers.Add_Class (Frame, "stat-card");

      Gtk.Box.Gtk_New_Vbox (Inner, Spacing => 14);
      Inner.Set_Margin_Start (20);
      Inner.Set_Margin_End (20);
      Inner.Set_Margin_Top (16);
      Inner.Set_Margin_Bottom (16);

      -- Recipient
      Gtk.Label.Gtk_New (Lbl, "RECIPIENT ADDRESS");
      GUI_Helpers.Add_Class (Lbl, "stat-label");
      Lbl.Set_Halign (Align_Start);
      Inner.Pack_Start (Lbl, Expand => False);

      Gtk.GEntry.Gtk_New (Tab.Recipient_Edit);
      Tab.Recipient_Edit.Set_Placeholder_Text
        ("ob1q... or classic address");
      Inner.Pack_Start (Tab.Recipient_Edit, Expand => False);

      -- Amount
      Gtk.Label.Gtk_New (Lbl, "AMOUNT (OMNI)");
      GUI_Helpers.Add_Class (Lbl, "stat-label");
      Lbl.Set_Halign (Align_Start);
      Inner.Pack_Start (Lbl, Expand => False);

      Gtk.Adjustment.Gtk_New
        (Adj,
         Value          => 0.0,
         Lower          => 0.0,
         Upper          => 21_000_000.0,
         Step_Increment => 0.001,
         Page_Increment => 1.0);
      Gtk.Spin_Button.Gtk_New (Tab.Amount_Spin, Adj, 0.001, Guint (9));
      Inner.Pack_Start (Tab.Amount_Spin, Expand => False);

      -- Fee
      Gtk.Box.Gtk_New_Hbox (Row, Spacing => 10);
      Gtk.Label.Gtk_New (Lbl, "ESTIMATED FEE:");
      GUI_Helpers.Add_Class (Lbl, "stat-label");
      Row.Pack_Start (Lbl, Expand => False);

      Gtk.Label.Gtk_New (Tab.Fee_Label, "0.000001000 OMNI (1000 sat)");
      GUI_Helpers.Add_Class (Tab.Fee_Label, "dim");
      Row.Pack_Start (Tab.Fee_Label, Expand => False);

      Inner.Pack_Start (Row, Expand => False);

      Frame.Add (Inner);
      Tab.Root.Pack_Start (Frame, Expand => False);

      -- Send button
      Gtk.Button.Gtk_New (Tab.Send_Btn, "Send Transaction");
      GUI_Helpers.Add_Class (Tab.Send_Btn, "accent");
      Tab.Send_Btn.Set_Size_Request (200, 40);
      Tab.Send_Btn.Set_Halign (Align_End);
      Tab.Root.Pack_Start (Tab.Send_Btn, Expand => False);

      -- Status
      Gtk.Label.Gtk_New (Tab.Status_Label, "");
      Tab.Status_Label.Set_Halign (Align_Start);
      Tab.Root.Pack_Start (Tab.Status_Label, Expand => False);

      return Tab;
   end Create;

   procedure Refresh (Tab : in out Send_Tab_Record) is
      R : RPC_Client.RPC_Result;
      pragma Unreferenced (R);
   begin
      -- Balance would come from RPC
      null;
   end Refresh;

   function Get_Widget (Tab : Send_Tab_Record)
      return Gtk.Widget.Gtk_Widget
   is
   begin
      return Gtk.Widget.Gtk_Widget (Tab.Root);
   end Get_Widget;

end Send_Tab;

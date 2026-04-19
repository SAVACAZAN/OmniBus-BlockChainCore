-- ============================================================
--  Receive_Tab body  --  Address display + copy
-- ============================================================

pragma Ada_2022;

with Gtk.Enums;  use Gtk.Enums;
with Gtk.Widget; use Gtk.Widget;
with Gtk.Frame;

with GUI_Helpers;
package body Receive_Tab is

   function Create return Receive_Tab_Record is
      Tab   : Receive_Tab_Record;
      Frame : Gtk.Frame.Gtk_Frame;
      Inner : Gtk.Box.Gtk_Box;
      Lbl   : Gtk.Label.Gtk_Label;
      Row   : Gtk.Box.Gtk_Box;
   begin
      Gtk.Box.Gtk_New_Vbox (Tab.Root, Spacing => 20);
      Tab.Root.Set_Margin_Start (40);
      Tab.Root.Set_Margin_End (40);
      Tab.Root.Set_Margin_Top (40);
      Tab.Root.Set_Margin_Bottom (40);

      -- Title
      Gtk.Label.Gtk_New (Lbl, "Receive OMNI");
      GUI_Helpers.Add_Class (Lbl, "title");
      Lbl.Set_Halign (Align_Center);
      Tab.Root.Pack_Start (Lbl, Expand => False);

      -- Address card
      Gtk.Frame.Gtk_New (Frame);
      GUI_Helpers.Add_Class (Frame, "stat-card");

      Gtk.Box.Gtk_New_Vbox (Inner, Spacing => 16);
      Inner.Set_Margin_Start (30);
      Inner.Set_Margin_End (30);
      Inner.Set_Margin_Top (30);
      Inner.Set_Margin_Bottom (30);

      Gtk.Label.Gtk_New (Lbl, "YOUR RECEIVE ADDRESS");
      GUI_Helpers.Add_Class (Lbl, "stat-label");
      Lbl.Set_Halign (Align_Center);
      Inner.Pack_Start (Lbl, Expand => False);

      -- Large address display
      Gtk.Label.Gtk_New (Tab.Address_Lbl,
         "ob1q_waiting_for_wallet...");
      GUI_Helpers.Add_Class (Tab.Address_Lbl, "mono");
      Tab.Address_Lbl.Set_Selectable (True);
      Tab.Address_Lbl.Set_Halign (Align_Center);
      Tab.Address_Lbl.Set_Line_Wrap (True);
      Inner.Pack_Start (Tab.Address_Lbl, Expand => False);

      -- Buttons
      Gtk.Box.Gtk_New_Hbox (Row, Spacing => 12);
      Row.Set_Halign (Align_Center);

      Gtk.Button.Gtk_New (Tab.Copy_Btn, "Copy Address");
      GUI_Helpers.Add_Class (Tab.Copy_Btn, "accent");
      Row.Pack_Start (Tab.Copy_Btn, Expand => False);

      Gtk.Button.Gtk_New (Tab.New_Addr_Btn, "Generate New Address");
      GUI_Helpers.Add_Class (Tab.New_Addr_Btn, "teal");
      Row.Pack_Start (Tab.New_Addr_Btn, Expand => False);

      Inner.Pack_Start (Row, Expand => False);

      Frame.Add (Inner);
      Tab.Root.Pack_Start (Frame, Expand => False);

      -- Info text
      Gtk.Label.Gtk_New (Tab.Info_Lbl,
         "OmniBus uses Bech32 addresses (ob1q...) compatible with " &
         "BIP-32 HD derivation." & ASCII.LF &
         "Post-quantum addresses are also supported via ML-DSA, " &
         "Falcon, SLH-DSA, and ML-KEM domains." & ASCII.LF &
         "Share this address to receive OMNI tokens. Each address " &
         "can be used multiple times.");
      GUI_Helpers.Add_Class (Tab.Info_Lbl, "dim");
      Tab.Info_Lbl.Set_Halign (Align_Center);
      Tab.Info_Lbl.Set_Line_Wrap (True);
      Tab.Info_Lbl.Set_Max_Width_Chars (80);
      Tab.Root.Pack_Start (Tab.Info_Lbl, Expand => False);

      return Tab;
   end Create;

   procedure Set_Address (Tab : in out Receive_Tab_Record; Addr : String) is
   begin
      Tab.Address_Lbl.Set_Text (Addr);
   end Set_Address;

   function Get_Widget (Tab : Receive_Tab_Record)
      return Gtk.Widget.Gtk_Widget
   is
   begin
      return Gtk.Widget.Gtk_Widget (Tab.Root);
   end Get_Widget;

end Receive_Tab;

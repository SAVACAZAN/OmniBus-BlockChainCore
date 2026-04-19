-- ============================================================
--  Wallet_Tab body  --  Multi-wallet hierarchy
-- ============================================================

pragma Ada_2022;

with Gtk.Enums;           use Gtk.Enums;
with Gtk.Widget; use Gtk.Widget;
with Gtk.Scrolled_Window;
with Gtk.Cell_Renderer_Text;
with Gtk.Tree_View_Column;
with Gtk.Separator;
with Gtk.Tree_Model;
with Glib;                use Glib;

with GUI_Helpers;
package body Wallet_Tab is

   Col_Name : constant := 0;
   Col_Type : constant := 1;
   Col_Addr : constant := 2;

   function Create return Wallet_Tab_Record is
      Tab : Wallet_Tab_Record;
      SW  : Gtk.Scrolled_Window.Gtk_Scrolled_Window;
      Sep : Gtk.Separator.Gtk_Separator;
      Lbl : Gtk.Label.Gtk_Label;
      HBox : Gtk.Box.Gtk_Box;
   begin
      Gtk.Box.Gtk_New_Vbox (Tab.Root, Spacing => 12);
      Tab.Root.Set_Margin_Start (20);
      Tab.Root.Set_Margin_End (20);
      Tab.Root.Set_Margin_Top (16);
      Tab.Root.Set_Margin_Bottom (16);

      -- Title + buttons
      Gtk.Box.Gtk_New_Hbox (HBox, Spacing => 10);

      Gtk.Label.Gtk_New (Lbl, "Multi-Wallet");
      GUI_Helpers.Add_Class (Lbl, "title");
      HBox.Pack_Start (Lbl, Expand => False);

      Gtk.Button.Gtk_New (Tab.Regen_Btn, "Regenerate Addresses");
      GUI_Helpers.Add_Class (Tab.Regen_Btn, "accent");
      HBox.Pack_End (Tab.Regen_Btn, Expand => False);

      Tab.Root.Pack_Start (HBox, Expand => False);

      -- Summary
      Gtk.Label.Gtk_New (Tab.Summary_Label, "No wallets loaded");
      GUI_Helpers.Add_Class (Tab.Summary_Label, "dim");
      Tab.Summary_Label.Set_Halign (Align_Start);
      Tab.Root.Pack_Start (Tab.Summary_Label, Expand => False);

      -- Tree store: Name, Type, Address
      Gtk.Tree_Store.Gtk_New
        (Tab.Store,
         (Col_Name => GType_String,
          Col_Type => GType_String,
          Col_Addr => GType_String));

      Gtk.Tree_View.Gtk_New (Tab.Tree, Tab.Store);
      Tab.Tree.Set_Headers_Visible (True);

      declare
         Ren : Gtk.Cell_Renderer_Text.Gtk_Cell_Renderer_Text;
         Col : Gtk.Tree_View_Column.Gtk_Tree_View_Column;
         Num : Gint;
         pragma Unreferenced (Num);
      begin
         for I in 0 .. 2 loop
            Gtk.Cell_Renderer_Text.Gtk_New (Ren);
            Gtk.Tree_View_Column.Gtk_New (Col);
            Col.Set_Title
              ((case I is
                  when 0 => "Name",
                  when 1 => "Type",
                  when others => "Address"));
            Col.Pack_Start (Ren, Expand => True);
            Col.Add_Attribute (Ren, "text", Gint (I));
            if I = 2 then
               Col.Set_Expand (True);
            end if;
            Num := Tab.Tree.Append_Column (Col);
         end loop;
      end;

      Gtk.Scrolled_Window.Gtk_New (SW);
      SW.Set_Policy (Policy_Automatic, Policy_Automatic);
      SW.Add (Tab.Tree);
      Tab.Root.Pack_Start (SW, Expand => True);

      -- Separator
      Gtk.Separator.Gtk_New_Hseparator (Sep);
      Tab.Root.Pack_Start (Sep, Expand => False);

      -- Detail panel
      Gtk.Box.Gtk_New_Hbox (HBox, Spacing => 10);

      Gtk.Label.Gtk_New (Tab.Detail_Label,
         "Select an address to view details");
      GUI_Helpers.Add_Class (Tab.Detail_Label, "mono");
      Tab.Detail_Label.Set_Selectable (True);
      HBox.Pack_Start (Tab.Detail_Label, Expand => True);

      Gtk.Button.Gtk_New (Tab.Copy_Btn, "Copy Address");
      HBox.Pack_End (Tab.Copy_Btn, Expand => False);

      Tab.Root.Pack_Start (HBox, Expand => False);

      return Tab;
   end Create;

   procedure Refresh (Tab : in out Wallet_Tab_Record) is
      Iter   : Gtk.Tree_Model.Gtk_Tree_Iter;
      Child  : Gtk.Tree_Model.Gtk_Tree_Iter;
   begin
      Tab.Store.Clear;

      -- Add default wallet with BIP-32 derived addresses
      Tab.Store.Append (Iter, Gtk.Tree_Model.Null_Iter);
      Tab.Store.Set (Iter, Col_Name, "OmniBus Wallet");
      Tab.Store.Set (Iter, Col_Type, "HD Wallet");
      Tab.Store.Set (Iter, Col_Addr, "");

      -- Account 0
      Tab.Store.Append (Child, Iter);
      Tab.Store.Set (Child, Col_Name, "Account #0");
      Tab.Store.Set (Child, Col_Type, "BIP-32");
      Tab.Store.Set (Child, Col_Addr, "");

      -- Sample addresses (would come from wallet/RPC in real usage)
      declare
         Addr_Iter : Gtk.Tree_Model.Gtk_Tree_Iter;
      begin
         for I in 0 .. 4 loop
            Tab.Store.Append (Addr_Iter, Child);
            Tab.Store.Set (Addr_Iter, Col_Name,
               "Address #" & Natural'Image (I));
            Tab.Store.Set (Addr_Iter, Col_Type, "Receive");
            Tab.Store.Set (Addr_Iter, Col_Addr,
               "ob1q_address_" & Natural'Image (I) & "...");
         end loop;
      end;

      -- PQ domains
      declare
         PQ_Iter  : Gtk.Tree_Model.Gtk_Tree_Iter;
         PQ_Child : Gtk.Tree_Model.Gtk_Tree_Iter;
         Domains  : constant array (1 .. 5) of String (1 .. 12) :=
           ("ML-DSA-87   ", "Falcon-512  ", "SLH-DSA-256s",
            "ML-KEM-768  ", "Classic     ");
      begin
         Tab.Store.Append (PQ_Iter, Iter);
         Tab.Store.Set (PQ_Iter, Col_Name, "PQ Domains");
         Tab.Store.Set (PQ_Iter, Col_Type, "Post-Quantum");
         Tab.Store.Set (PQ_Iter, Col_Addr, "");

         for D of Domains loop
            Tab.Store.Append (PQ_Child, PQ_Iter);
            Tab.Store.Set (PQ_Child, Col_Name, D);
            Tab.Store.Set (PQ_Child, Col_Type, "PQ");
            Tab.Store.Set (PQ_Child, Col_Addr, "ob1q_pq_...");
         end loop;
      end;

      Tab.Summary_Label.Set_Text ("1 wallet, 5 addresses, 5 PQ domains");

      Tab.Tree.Expand_All;
   end Refresh;

   function Get_Widget (Tab : Wallet_Tab_Record)
      return Gtk.Widget.Gtk_Widget
   is
   begin
      return Gtk.Widget.Gtk_Widget (Tab.Root);
   end Get_Widget;

end Wallet_Tab;

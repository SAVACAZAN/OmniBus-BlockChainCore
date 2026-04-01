-- ============================================================
--  Exchange_Keys_Tab body  --  Vault key management via GtkAda
-- ============================================================

pragma Ada_2022;

with Gtk.Enums;           use Gtk.Enums;
with Gtk.Scrolled_Window;
with Gtk.Cell_Renderer_Text;
with Gtk.Tree_View_Column;
with Gtk.Tree_Model;
with Gtk.Separator;
with Glib;                use Glib;
with Vault_Types;         use Vault_Types;
with Vault_Storage;
with Exchange_Manager;

with GUI_Helpers;
package body Exchange_Keys_Tab is

   Col_Slot   : constant := 0;
   Col_Name   : constant := 1;
   Col_ApiKey : constant := 2;
   Col_Status : constant := 3;

   -- ── Create one exchange panel ─────────────────────────────

   function Create_Panel (Ex : Exchange_Id) return Exchange_Panel_Record is
      Panel : Exchange_Panel_Record;
      SW    : Gtk.Scrolled_Window.Gtk_Scrolled_Window;
      HBox  : Gtk.Box.Gtk_Box;
      Lbl   : Gtk.Label.Gtk_Label;
   begin
      Panel.Exchange := Ex;

      Gtk.Box.Gtk_New_Vbox (Panel.Root, Spacing => 10);
      Panel.Root.Set_Margin_Start (16);
      Panel.Root.Set_Margin_End (16);
      Panel.Root.Set_Margin_Top (12);
      Panel.Root.Set_Margin_Bottom (12);

      -- Header row
      Gtk.Box.Gtk_New_Hbox (HBox, Spacing => 10);

      Gtk.Label.Gtk_New (Lbl,
         Exchange_Name (Ex) & " -- API Keys");
      GUI_Helpers.Add_Class (Lbl, "title");
      HBox.Pack_Start (Lbl, Expand => False);

      Gtk.Label.Gtk_New (Panel.Count_Lbl, "0 / 8 keys");
      GUI_Helpers.Add_Class (Panel.Count_Lbl, "dim");
      HBox.Pack_End (Panel.Count_Lbl, Expand => False);

      Panel.Root.Pack_Start (HBox, Expand => False);

      -- Button row
      Gtk.Box.Gtk_New_Hbox (HBox, Spacing => 8);

      Gtk.Button.Gtk_New (Panel.Add_Btn, "+ Add Key");
      GUI_Helpers.Add_Class (Panel.Add_Btn, "teal");
      HBox.Pack_Start (Panel.Add_Btn, Expand => False);

      Gtk.Button.Gtk_New (Panel.Edit_Btn, "Edit");
      HBox.Pack_Start (Panel.Edit_Btn, Expand => False);

      Gtk.Button.Gtk_New (Panel.Delete_Btn, "Delete");
      GUI_Helpers.Add_Class (Panel.Delete_Btn, "destructive");
      HBox.Pack_Start (Panel.Delete_Btn, Expand => False);

      Panel.Root.Pack_Start (HBox, Expand => False);

      -- Keys table
      Gtk.List_Store.Gtk_New
        (Panel.Store,
         (Col_Slot   => GType_String,
          Col_Name   => GType_String,
          Col_ApiKey => GType_String,
          Col_Status => GType_String));

      Gtk.Tree_View.Gtk_New (Panel.Tree, Panel.Store);
      Panel.Tree.Set_Headers_Visible (True);

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
                  when 0 => "Slot",
                  when 1 => "Name",
                  when 2 => "API Key",
                  when others => "Status"));
            Col.Pack_Start (Ren, Expand => True);
            Col.Add_Attribute (Ren, "text", Gint (I));
            Col.Set_Resizable (True);
            if I = 2 then
               Col.Set_Expand (True);
            end if;
            Num := Panel.Tree.Append_Column (Col);
         end loop;
      end;

      Gtk.Scrolled_Window.Gtk_New (SW);
      SW.Set_Policy (Policy_Automatic, Policy_Automatic);
      SW.Add (Panel.Tree);
      Panel.Root.Pack_Start (SW, Expand => True);

      return Panel;
   end Create_Panel;

   -- ── Create main tab ───────────────────────────────────────

   function Create return Exchange_Keys_Tab_Record is
      Tab  : Exchange_Keys_Tab_Record;
      HBox : Gtk.Box.Gtk_Box;
      Sep  : Gtk.Separator.Gtk_Separator;
      Lbl  : Gtk.Label.Gtk_Label;
   begin
      Gtk.Box.Gtk_New_Vbox (Tab.Root, Spacing => 10);
      Tab.Root.Set_Margin_Start (20);
      Tab.Root.Set_Margin_End (20);
      Tab.Root.Set_Margin_Top (16);
      Tab.Root.Set_Margin_Bottom (16);

      -- Header: title + lock controls
      Gtk.Box.Gtk_New_Hbox (HBox, Spacing => 12);

      Gtk.Label.Gtk_New (Lbl, "Exchange Keys");
      GUI_Helpers.Add_Class (Lbl, "title");
      HBox.Pack_Start (Lbl, Expand => False);

      -- SPARK badge
      Gtk.Label.Gtk_New (Lbl, "SPARK VERIFIED");
      GUI_Helpers.Add_Class (Lbl, "spark-badge");
      HBox.Pack_Start (Lbl, Expand => False);

      -- Vault path
      Gtk.Label.Gtk_New (Tab.Vault_Path, "Vault: ...");
      GUI_Helpers.Add_Class (Tab.Vault_Path, "dim");
      HBox.Pack_Start (Tab.Vault_Path, Expand => True);

      -- Status
      Gtk.Label.Gtk_New (Tab.Status_Lbl, "Locked");
      HBox.Pack_End (Tab.Status_Lbl, Expand => False);

      -- Lock button
      Gtk.Button.Gtk_New (Tab.Lock_Btn, "Unlock");
      GUI_Helpers.Add_Class (Tab.Lock_Btn, "teal");
      HBox.Pack_End (Tab.Lock_Btn, Expand => False);

      Tab.Root.Pack_Start (HBox, Expand => False);

      -- Separator
      Gtk.Separator.Gtk_New_Hseparator (Sep);
      Tab.Root.Pack_Start (Sep, Expand => False);

      -- Sub-notebook with exchange tabs
      Gtk.Notebook.Gtk_New (Tab.Sub_Tabs);

      for Ex in Exchange_Id loop
         Tab.Panels (Ex) := Create_Panel (Ex);
         declare
            Tab_Lbl : Gtk.Label.Gtk_Label;
         begin
            Gtk.Label.Gtk_New (Tab_Lbl, Exchange_Name (Ex));
            Tab.Sub_Tabs.Append_Page (Tab.Panels (Ex).Root, Tab_Lbl);
         end;
      end loop;

      Tab.Root.Pack_Start (Tab.Sub_Tabs, Expand => True);

      return Tab;
   end Create;

   -- ── Refresh panel from vault ──────────────────────────────

   procedure Refresh_Panel (Panel : in out Exchange_Panel_Record) is
      Iter : Gtk.Tree_Model.Gtk_Tree_Iter;
      Count : Natural := 0;
   begin
      Panel.Store.Clear;

      if not Vault_Storage.Is_Loaded then
         Panel.Count_Lbl.Set_Text ("Vault locked");
         return;
      end if;

      for S in Slot_Index loop
         declare
            E : constant Key_Entry :=
               Vault_Storage.Get_Key (Panel.Exchange, S);
         begin
            if E.In_Use then
               Panel.Store.Append (Iter);
               Panel.Store.Set (Iter, Col_Slot, Natural'Image (Natural (S)));
               Panel.Store.Set (Iter, Col_Name,
                  E.Name.Data (1 .. E.Name.Len));

               -- Mask API key
               if E.Api_Key.Len > 12 then
                  Panel.Store.Set (Iter, Col_ApiKey,
                     E.Api_Key.Data (1 .. 6) & "***" &
                     E.Api_Key.Data (E.Api_Key.Len - 3 .. E.Api_Key.Len));
               else
                  Panel.Store.Set (Iter, Col_ApiKey,
                     E.Api_Key.Data (1 .. E.Api_Key.Len));
               end if;

               Panel.Store.Set (Iter, Col_Status,
                  Status_Name (E.Status));

               Count := Count + 1;
            end if;
         end;
      end loop;

      Panel.Count_Lbl.Set_Text
        (Natural'Image (Count) & " / 8 keys");
   end Refresh_Panel;

   -- ── Refresh all panels ────────────────────────────────────

   procedure Refresh_All (Tab : in out Exchange_Keys_Tab_Record) is
   begin
      if Vault_Storage.Is_Loaded then
         Tab.Status_Lbl.Set_Text ("Unlocked");
         GUI_Helpers.Add_Class (Tab.Status_Lbl, "teal");
         Tab.Lock_Btn.Set_Label ("Lock");
         GUI_Helpers.Remove_Class (Tab.Lock_Btn, "teal");
         GUI_Helpers.Add_Class (Tab.Lock_Btn, "destructive");
      else
         Tab.Status_Lbl.Set_Text ("Locked");
         GUI_Helpers.Remove_Class (Tab.Status_Lbl, "teal");
         Tab.Lock_Btn.Set_Label ("Unlock");
         GUI_Helpers.Remove_Class (Tab.Lock_Btn, "destructive");
         GUI_Helpers.Add_Class (Tab.Lock_Btn, "teal");
      end if;

      Tab.Vault_Path.Set_Text
        ("Vault: " & Vault_Storage.Vault_File_Path);

      for Ex in Exchange_Id loop
         Refresh_Panel (Tab.Panels (Ex));
      end loop;
   end Refresh_All;

   -- ── Get widget ────────────────────────────────────────────

   function Get_Widget (Tab : Exchange_Keys_Tab_Record)
      return Gtk.Widget.Gtk_Widget
   is
   begin
      return Gtk.Widget.Gtk_Widget (Tab.Root);
   end Get_Widget;

end Exchange_Keys_Tab;

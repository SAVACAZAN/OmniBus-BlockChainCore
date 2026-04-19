-- ============================================================
--  Welcome_Dialog body  --  Modal startup dialog
-- ============================================================

pragma Ada_2022;

with Gtk.Dialog;          use Gtk.Dialog;
with Gtk.Box;
with Gtk.Label;
with Gtk.Button;
with Gtk.Separator;
with Gtk.Enums;           use Gtk.Enums;
with Gtk.Widget;          use Gtk.Widget;
with Glib;                use Glib;

with GUI_Helpers;

package body Welcome_Dialog is

   -- We store the choice in a package-level variable so signal
   -- callbacks (which are parameterless) can set it.
   Result_Choice : User_Choice := No_Choice;
   Dialog_Ptr    : Gtk.Dialog.Gtk_Dialog := null;

   -- ── Button callbacks ──────────────────────────────────────

   procedure On_Create_Clicked
     (Self : access Gtk.Button.Gtk_Button_Record'Class)
   is
      pragma Unreferenced (Self);
   begin
      Result_Choice := Create_Wallet;
      Dialog_Ptr.Response (Gtk_Response_OK);
   end On_Create_Clicked;

   procedure On_Import_Clicked
     (Self : access Gtk.Button.Gtk_Button_Record'Class)
   is
      pragma Unreferenced (Self);
   begin
      Result_Choice := Import_Wallet;
      Dialog_Ptr.Response (Gtk_Response_OK);
   end On_Import_Clicked;

   procedure On_Connect_Clicked
     (Self : access Gtk.Button.Gtk_Button_Record'Class)
   is
      pragma Unreferenced (Self);
   begin
      Result_Choice := Connect_Node;
      Dialog_Ptr.Response (Gtk_Response_OK);
   end On_Connect_Clicked;

   -- ── Run ───────────────────────────────────────────────────

   function Run return User_Choice is
      Dlg     : Gtk.Dialog.Gtk_Dialog;
      Content : Gtk.Box.Gtk_Box;
      Lbl     : Gtk.Label.Gtk_Label;
      Sep     : Gtk.Separator.Gtk_Separator;
      Btn     : Gtk.Button.Gtk_Button;
      Desc    : Gtk.Label.Gtk_Label;
      R       : Gtk_Response_Type;
      pragma Unreferenced (R);
   begin
      Result_Choice := No_Choice;

      Gtk.Dialog.Gtk_New (Dlg);
      Dialog_Ptr := Dlg;
      Dlg.Set_Title ("OmniBus Wallet");
      Dlg.Set_Default_Size (500, 460);
      Dlg.Set_Position (Win_Pos_Center);
      Dlg.Set_Resizable (False);

      Content := Dlg.Get_Content_Area;
      Content.Set_Spacing (12);
      Content.Set_Margin_Start (40);
      Content.Set_Margin_End (40);
      Content.Set_Margin_Top (30);
      Content.Set_Margin_Bottom (30);

      -- Title
      Gtk.Label.Gtk_New (Lbl, "OmniBus");
      GUI_Helpers.Add_Class (Lbl, "balance");
      Lbl.Set_Halign (Align_Center);
      Content.Pack_Start (Lbl, Expand => False);

      -- Subtitle
      Gtk.Label.Gtk_New (Lbl, "Post-Quantum Blockchain Wallet");
      GUI_Helpers.Add_Class (Lbl, "dim");
      Lbl.Set_Halign (Align_Center);
      Content.Pack_Start (Lbl, Expand => False);

      -- Separator
      Gtk.Separator.Gtk_New_Hseparator (Sep);
      Content.Pack_Start (Sep, Expand => False);

      -- ── Create Wallet button ───────────────────────────────
      Gtk.Button.Gtk_New (Btn, "Create New Wallet");
      GUI_Helpers.Add_Class (Btn, "accent");
      Btn.Set_Size_Request (-1, 56);
      Btn.On_Clicked (On_Create_Clicked'Access);
      Content.Pack_Start (Btn, Expand => False);

      Gtk.Label.Gtk_New (Desc,
         "Generate a new mnemonic phrase and create a fresh wallet");
      GUI_Helpers.Add_Class (Desc, "dim");
      Desc.Set_Halign (Align_Start);
      Desc.Set_Margin_Start (20);
      Content.Pack_Start (Desc, Expand => False);

      -- ── Import Wallet button ───────────────────────────────
      Gtk.Button.Gtk_New (Btn, "Import Existing Wallet");
      Btn.Set_Size_Request (-1, 56);
      Btn.On_Clicked (On_Import_Clicked'Access);
      Content.Pack_Start (Btn, Expand => False);

      Gtk.Label.Gtk_New (Desc,
         "Restore a wallet from a mnemonic phrase or backup file");
      GUI_Helpers.Add_Class (Desc, "dim");
      Desc.Set_Halign (Align_Start);
      Desc.Set_Margin_Start (20);
      Content.Pack_Start (Desc, Expand => False);

      -- ── Connect to Node button ─────────────────────────────
      Gtk.Button.Gtk_New (Btn, "Connect to Running Node");
      Btn.Set_Size_Request (-1, 56);
      Btn.On_Clicked (On_Connect_Clicked'Access);
      Content.Pack_Start (Btn, Expand => False);

      Gtk.Label.Gtk_New (Desc,
         "Use the wallet from an existing OmniBus node (spectator mode)");
      GUI_Helpers.Add_Class (Desc, "dim");
      Desc.Set_Halign (Align_Start);
      Desc.Set_Margin_Start (20);
      Content.Pack_Start (Desc, Expand => False);

      -- Spacer
      Gtk.Label.Gtk_New (Lbl, "");
      Content.Pack_Start (Lbl, Expand => True);

      -- Version
      Gtk.Label.Gtk_New (Lbl, "OmniBus-Ada v1.0.0");
      GUI_Helpers.Add_Class (Lbl, "dim");
      Lbl.Set_Halign (Align_Center);
      Content.Pack_Start (Lbl, Expand => False);

      Dlg.Show_All;
      R := Dlg.Run;
      Dlg.Destroy;
      Dialog_Ptr := null;

      return Result_Choice;
   end Run;

end Welcome_Dialog;

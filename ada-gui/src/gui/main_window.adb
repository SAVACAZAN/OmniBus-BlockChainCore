-- ============================================================
--  Main_Window body  --  with signal handlers + full refresh
-- ============================================================

pragma Ada_2022;

with Gtk.Enums;           use Gtk.Enums;
with Gtk.Widget;
with Gtk.Box;
with Gtk.Label;
with Gtk.Separator;
with Gtk.Menu_Bar;
with Gtk.Menu;
with Gtk.Menu_Item;
with Gtk.Main;
with Gtk.Button;
with Gtk.Clipboard;
with Gtk.GEntry;
with Gtk.Spin_Button;
with Glib;                use Glib;
with RPC_Client;
with Ada.Text_IO;

with GUI_Helpers;
package body Main_Window is

   -- ── Forward-declared package-level state for signal handlers ──
   --  GtkAda signal callbacks need access to the window record.
   --  We store a pointer here after Create.
   Current_Win : Main_Window_Access := null;

   -- ── Signal handler: Send button ───────────────────────────

   procedure On_Send_Clicked
     (Self : access Gtk.Button.Gtk_Button_Record'Class)
   is
      pragma Unreferenced (Self);
      W : Main_Window_Record renames Current_Win.all;
      Recipient : constant String := W.Send.Recipient_Edit.Get_Text;
      Amount_F  : constant Glib.Gdouble := W.Send.Amount_Spin.Get_Value;
      Amount    : constant Long_Long_Integer :=
         Long_Long_Integer (Amount_F * 1_000_000_000.0);
      Fee       : constant Long_Long_Integer := 1_000;
      R         : RPC_Client.RPC_Result;
   begin
      if Recipient'Length = 0 then
         W.Send.Status_Label.Set_Text ("Error: enter a recipient address");
         GUI_Helpers.Add_Class (W.Send.Status_Label, "destructive");
         return;
      end if;
      if Amount <= 0 then
         W.Send.Status_Label.Set_Text ("Error: amount must be > 0");
         return;
      end if;

      W.Send.Status_Label.Set_Text ("Sending...");

      RPC_Client.Send_Transaction
        (From_Addr => "default",
         To_Addr   => Recipient,
         Amount    => Amount,
         Fee       => Fee,
         Result    => R);

      if R.Success then
         W.Send.Status_Label.Set_Text ("Transaction sent!");
         GUI_Helpers.Add_Class (W.Send.Status_Label, "teal");
         W.Send.Recipient_Edit.Set_Text ("");
         W.Send.Amount_Spin.Set_Value (0.0);
      else
         W.Send.Status_Label.Set_Text
           ("Error: could not connect to node");
      end if;
   exception
      when others =>
         W.Send.Status_Label.Set_Text ("Error: send failed");
   end On_Send_Clicked;

   -- ── Signal handler: Copy address (Receive tab) ────────────

   procedure On_Copy_Receive
     (Self : access Gtk.Button.Gtk_Button_Record'Class)
   is
      pragma Unreferenced (Self);
      W   : Main_Window_Record renames Current_Win.all;
      Addr : constant String := W.Receive.Address_Lbl.Get_Text;
   begin
      Gtk.Clipboard.Get.Set_Text (Addr);
      Ada.Text_IO.Put_Line ("Copied address to clipboard: " & Addr);
   exception
      when others => null;
   end On_Copy_Receive;

   -- ── Signal handler: Copy address (Wallet tab) ─────────────

   procedure On_Copy_Wallet
     (Self : access Gtk.Button.Gtk_Button_Record'Class)
   is
      pragma Unreferenced (Self);
      W    : Main_Window_Record renames Current_Win.all;
      Addr : constant String := W.Multi_Wallet.Detail_Label.Get_Text;
   begin
      Gtk.Clipboard.Get.Set_Text (Addr);
   exception
      when others => null;
   end On_Copy_Wallet;

   -- ── Signal handler: Generate new address ──────────────────

   procedure On_New_Addr
     (Self : access Gtk.Button.Gtk_Button_Record'Class)
   is
      pragma Unreferenced (Self);
      W : Main_Window_Record renames Current_Win.all;
   begin
      -- Ask node for new derived address
      declare
         R : RPC_Client.RPC_Result;
      begin
         RPC_Client.Call ("getnewaddress", "{}", R);
         if R.Success then
            declare
               Addr : constant String :=
                  RPC_Client.Extract_String (R.Data (1 .. R.Len), "result");
            begin
               if Addr'Length > 0 then
                  Receive_Tab.Set_Address (W.Receive, Addr);
                  W.Addr_Label.Set_Text (Addr);
               end if;
            end;
         end if;
      end;
   exception
      when others => null;
   end On_New_Addr;

   -- ── Signal handler: Block search ──────────────────────────

   procedure On_Block_Search
     (Self : access Gtk.Button.Gtk_Button_Record'Class)
   is
      pragma Unreferenced (Self);
      W     : Main_Window_Record renames Current_Win.all;
      Query : constant String := W.Explorer.Search_Entry.Get_Text;
      R     : RPC_Client.RPC_Result;
   begin
      if Query'Length = 0 then
         return;
      end if;

      -- Try as height first (all digits?)
      declare
         Is_Number : Boolean := True;
      begin
         for C of Query loop
            if C not in '0' .. '9' then
               Is_Number := False;
               exit;
            end if;
         end loop;

         if Is_Number then
            RPC_Client.Get_Block (Natural'Value (Query), R);
         else
            RPC_Client.Get_Block_By_Hash (Query, R);
         end if;
      end;

      if R.Success then
         W.Explorer.Detail_Label.Set_Text (R.Data (1 .. R.Len));
         GUI_Helpers.Remove_Class (W.Explorer.Detail_Label, "dim");
         GUI_Helpers.Add_Class (W.Explorer.Detail_Label, "mono");
      else
         W.Explorer.Detail_Label.Set_Text
           ("Block not found or node offline");
      end if;
   exception
      when others =>
         W.Explorer.Detail_Label.Set_Text ("Search error");
   end On_Block_Search;

   -- ── Signal handler: Console Enter key ─────────────────────

   procedure On_Console_Activate
     (Self : access Gtk.GEntry.Gtk_Entry_Record'Class)
   is
      pragma Unreferenced (Self);
   begin
      Console_Tab.Execute_Input (Current_Win.Console);
   exception
      when others => null;
   end On_Console_Activate;

   -- ── Signal handler: Quit menu ───────────────────────────────

   procedure On_Quit_Activate
     (Self : access Gtk.Menu_Item.Gtk_Menu_Item_Record'Class)
   is
      pragma Unreferenced (Self);
   begin
      Gtk.Main.Main_Quit;
   end On_Quit_Activate;

   -- ── Signal handler: Lock/Unlock vault ─────────────────────

   procedure On_Lock_Clicked
     (Self : access Gtk.Button.Gtk_Button_Record'Class)
   is
      pragma Unreferenced (Self);
      W : Main_Window_Record renames Current_Win.all;
   begin
      -- Toggle vault state
      Exchange_Keys_Tab.Refresh_All (W.Exchange_Keys);
   exception
      when others => null;
   end On_Lock_Clicked;

   -- ── Signal handler: Regenerate addresses ──────────────────

   procedure On_Regen_Clicked
     (Self : access Gtk.Button.Gtk_Button_Record'Class)
   is
      pragma Unreferenced (Self);
   begin
      Wallet_Tab.Refresh (Current_Win.Multi_Wallet);
   exception
      when others => null;
   end On_Regen_Clicked;

   -- ── Signal handler: Transactions refresh ──────────────────

   procedure On_Tx_Refresh
     (Self : access Gtk.Button.Gtk_Button_Record'Class)
   is
      pragma Unreferenced (Self);
   begin
      Transactions_Tab.Refresh (Current_Win.Transactions);
   exception
      when others => null;
   end On_Tx_Refresh;

   -- ── Create ────────────────────────────────────────────────

   procedure Create (Win : out Main_Window_Record) is
      Menu_Bar  : Gtk.Menu_Bar.Gtk_Menu_Bar;
      File_Menu : Gtk.Menu.Gtk_Menu;
      View_Menu : Gtk.Menu.Gtk_Menu;
      Help_Menu : Gtk.Menu.Gtk_Menu;
      Item      : Gtk.Menu_Item.Gtk_Menu_Item;
      Toolbar   : Gtk.Box.Gtk_Box;
      Statusbar : Gtk.Box.Gtk_Box;
      Sep       : Gtk.Separator.Gtk_Separator;
      Lbl       : Gtk.Label.Gtk_Label;
   begin
      -- Window
      Gtk.Window.Gtk_New (Win.Window);
      Win.Window.Set_Title ("OmniBus-Ada -- Blockchain Wallet");
      Win.Window.Set_Default_Size (1200, 800);
      Win.Window.Set_Position (Win_Pos_Center);

      -- Main vertical box
      Gtk.Box.Gtk_New_Vbox (Win.Main_Box, Spacing => 0);
      Win.Window.Add (Win.Main_Box);

      -- ── Menu Bar ───────────────────────────────────────────
      Gtk.Menu_Bar.Gtk_New (Menu_Bar);

      -- File menu
      Gtk.Menu.Gtk_New (File_Menu);
      Gtk.Menu_Item.Gtk_New (Item, "New Wallet...");
      File_Menu.Append (Item);
      Gtk.Menu_Item.Gtk_New (Item, "Import Wallet...");
      File_Menu.Append (Item);
      Gtk.Menu_Item.Gtk_New (Item);  -- separator
      File_Menu.Append (Item);
      Gtk.Menu_Item.Gtk_New (Item, "Settings...");
      File_Menu.Append (Item);
      Gtk.Menu_Item.Gtk_New (Item);  -- separator
      File_Menu.Append (Item);

      -- Quit menu item with handler
      Gtk.Menu_Item.Gtk_New (Win.Quit_Item, "Quit");
      File_Menu.Append (Win.Quit_Item);

      Gtk.Menu_Item.Gtk_New (Item, "File");
      Item.Set_Submenu (File_Menu);
      Menu_Bar.Append (Item);

      -- View menu
      Gtk.Menu.Gtk_New (View_Menu);
      declare
         Tab_Names : constant array (1 .. 10) of String (1 .. 14) :=
           ["Overview      ", "Multi-Wallet  ", "Send          ",
            "Receive       ", "Transactions  ", "Mining        ",
            "Network       ", "Block Explorer", "Console       ",
            "Exchange Keys "];
      begin
         for N of Tab_Names loop
            Gtk.Menu_Item.Gtk_New (Item, N);
            View_Menu.Append (Item);
         end loop;
      end;

      Gtk.Menu_Item.Gtk_New (Item, "View");
      Item.Set_Submenu (View_Menu);
      Menu_Bar.Append (Item);

      -- Help menu
      Gtk.Menu.Gtk_New (Help_Menu);
      Gtk.Menu_Item.Gtk_New (Item, "About OmniBus-Ada");
      Help_Menu.Append (Item);

      Gtk.Menu_Item.Gtk_New (Item, "Help");
      Item.Set_Submenu (Help_Menu);
      Menu_Bar.Append (Item);

      Win.Main_Box.Pack_Start (Menu_Bar, Expand => False);

      -- ── Wallet Toolbar ─────────────────────────────────────
      Gtk.Box.Gtk_New_Hbox (Toolbar, Spacing => 10);
      Toolbar.Set_Margin_Start (12);
      Toolbar.Set_Margin_End (12);
      Toolbar.Set_Margin_Top (6);
      Toolbar.Set_Margin_Bottom (6);

      -- Wallet label
      Gtk.Label.Gtk_New (Lbl, "Wallet:");
      GUI_Helpers.Add_Class (Lbl, "dim");
      Toolbar.Pack_Start (Lbl, Expand => False);

      -- Wallet combo
      Gtk.Combo_Box_Text.Gtk_New (Win.Wallet_Combo);
      Win.Wallet_Combo.Append_Text ("OmniBus Wallet");
      Win.Wallet_Combo.Set_Active (0);
      Toolbar.Pack_Start (Win.Wallet_Combo, Expand => False);

      -- Separator
      Gtk.Separator.Gtk_New_Vseparator (Sep);
      Toolbar.Pack_Start (Sep, Expand => False);

      -- Address
      Gtk.Label.Gtk_New (Win.Addr_Label, "ob1q...");
      GUI_Helpers.Add_Class (Win.Addr_Label, "mono");
      Win.Addr_Label.Set_Selectable (True);
      Toolbar.Pack_Start (Win.Addr_Label, Expand => False);

      -- Separator
      Gtk.Separator.Gtk_New_Vseparator (Sep);
      Toolbar.Pack_Start (Sep, Expand => False);

      -- Balance
      Gtk.Label.Gtk_New (Win.Balance_Label, "0.000000000 OMNI");
      GUI_Helpers.Add_Class (Win.Balance_Label, "teal");
      Toolbar.Pack_Start (Win.Balance_Label, Expand => False);

      -- Spacer
      Gtk.Label.Gtk_New (Lbl, "");
      Toolbar.Pack_Start (Lbl, Expand => True);

      -- Lock button
      Gtk.Button.Gtk_New (Win.Lock_Btn, "Lock");
      Toolbar.Pack_End (Win.Lock_Btn, Expand => False);

      Win.Main_Box.Pack_Start (Toolbar, Expand => False);

      -- Toolbar separator
      Gtk.Separator.Gtk_New_Hseparator (Sep);
      Win.Main_Box.Pack_Start (Sep, Expand => False);

      -- ── Notebook (10 tabs) ─────────────────────────────────
      Gtk.Notebook.Gtk_New (Win.Notebook);
      Win.Notebook.Set_Scrollable (True);

      -- Create all tabs
      Win.Overview      := Overview_Tab.Create;
      Win.Multi_Wallet  := Wallet_Tab.Create;
      Win.Send          := Send_Tab.Create;
      Win.Receive       := Receive_Tab.Create;
      Win.Transactions  := Transactions_Tab.Create;
      Win.Mining        := Mining_Tab.Create;
      Win.Network       := Network_Tab.Create;
      Win.Explorer      := Block_Explorer_Tab.Create;
      Win.Console       := Console_Tab.Create;
      Win.Exchange_Keys := Exchange_Keys_Tab.Create;

      -- Add tabs to notebook
      declare
         procedure Add_Tab (W : Gtk.Widget.Gtk_Widget; Title : String) is
            L : Gtk.Label.Gtk_Label;
         begin
            Gtk.Label.Gtk_New (L, Title);
            Win.Notebook.Append_Page (W, L);
         end Add_Tab;
      begin
         Add_Tab (Overview_Tab.Get_Widget (Win.Overview), "Overview");
         Add_Tab (Wallet_Tab.Get_Widget (Win.Multi_Wallet), "Multi-Wallet");
         Add_Tab (Send_Tab.Get_Widget (Win.Send), "Send");
         Add_Tab (Receive_Tab.Get_Widget (Win.Receive), "Receive");
         Add_Tab (Transactions_Tab.Get_Widget (Win.Transactions),
                  "Transactions");
         Add_Tab (Mining_Tab.Get_Widget (Win.Mining), "Mining");
         Add_Tab (Network_Tab.Get_Widget (Win.Network), "Network");
         Add_Tab (Block_Explorer_Tab.Get_Widget (Win.Explorer), "Blocks");
         Add_Tab (Console_Tab.Get_Widget (Win.Console), "Console");
         Add_Tab (Exchange_Keys_Tab.Get_Widget (Win.Exchange_Keys),
                  "Exchange Keys");
      end;

      Win.Main_Box.Pack_Start (Win.Notebook, Expand => True);

      -- ── Status Bar ─────────────────────────────────────────
      Gtk.Box.Gtk_New_Hbox (Statusbar, Spacing => 16);
      GUI_Helpers.Add_Class (Statusbar, "statusbar");
      Statusbar.Set_Margin_Start (12);
      Statusbar.Set_Margin_End (12);
      Statusbar.Set_Margin_Top (4);
      Statusbar.Set_Margin_Bottom (4);

      Gtk.Label.Gtk_New (Win.Status_Label, "OmniBus-Ada v1.0.0");
      GUI_Helpers.Add_Class (Win.Status_Label, "dim");
      Statusbar.Pack_Start (Win.Status_Label, Expand => False);

      Gtk.Label.Gtk_New (Lbl, "");
      Statusbar.Pack_Start (Lbl, Expand => True);

      Gtk.Label.Gtk_New (Win.Height_Status, "Block: 0");
      GUI_Helpers.Add_Class (Win.Height_Status, "dim");
      Statusbar.Pack_End (Win.Height_Status, Expand => False);

      Gtk.Label.Gtk_New (Win.Peer_Status, "Peers: 0");
      GUI_Helpers.Add_Class (Win.Peer_Status, "dim");
      Statusbar.Pack_End (Win.Peer_Status, Expand => False);

      Gtk.Label.Gtk_New (Win.WS_Status, "WS: disconnected");
      GUI_Helpers.Add_Class (Win.WS_Status, "dim");
      Statusbar.Pack_End (Win.WS_Status, Expand => False);

      Gtk.Separator.Gtk_New_Hseparator (Sep);
      Win.Main_Box.Pack_Start (Sep, Expand => False);
      Win.Main_Box.Pack_Start (Statusbar, Expand => False);

   end Create;

   -- ── Connect Signals ───────────────────────────────────────

   procedure Connect_Signals (Win_Ptr : Main_Window_Access) is
      W : Main_Window_Record renames Win_Ptr.all;
   begin
      Current_Win := Win_Ptr;

      -- Send tab: Send button
      W.Send.Send_Btn.On_Clicked (On_Send_Clicked'Access);

      -- Receive tab: Copy + New Address
      W.Receive.Copy_Btn.On_Clicked (On_Copy_Receive'Access);
      W.Receive.New_Addr_Btn.On_Clicked (On_New_Addr'Access);

      -- Wallet tab: Copy + Regenerate
      W.Multi_Wallet.Copy_Btn.On_Clicked (On_Copy_Wallet'Access);
      W.Multi_Wallet.Regen_Btn.On_Clicked (On_Regen_Clicked'Access);

      -- Block Explorer: Search button
      W.Explorer.Search_Btn.On_Clicked (On_Block_Search'Access);

      -- Console: Enter key on input entry
      W.Console.Input_Entry.On_Activate (On_Console_Activate'Access);

      -- Toolbar: Lock button
      W.Lock_Btn.On_Clicked (On_Lock_Clicked'Access);

      -- Transactions: Refresh button
      W.Transactions.Refresh_Btn.On_Clicked (On_Tx_Refresh'Access);

      -- Quit menu item
      W.Quit_Item.On_Activate (On_Quit_Activate'Access);

   end Connect_Signals;

   -- ── Show ──────────────────────────────────────────────────

   procedure Show (Win : Main_Window_Record) is
   begin
      Win.Window.Show_All;
   end Show;

   -- ── Refresh All ───────────────────────────────────────────

   procedure Refresh_All (Win : in out Main_Window_Record) is
   begin
      -- Overview tab
      begin
         Overview_Tab.Refresh (Win.Overview);
      exception
         when others => null;
      end;

      -- Wallet tab — populate tree with addresses
      begin
         Wallet_Tab.Refresh (Win.Multi_Wallet);
      exception
         when others => null;
      end;

      -- Mining tab
      begin
         Mining_Tab.Refresh (Win.Mining);
      exception
         when others => null;
      end;

      -- Network tab
      begin
         Network_Tab.Refresh (Win.Network);
      exception
         when others => null;
      end;

      -- Transactions tab
      begin
         Transactions_Tab.Refresh (Win.Transactions);
      exception
         when others => null;
      end;

      -- Block Explorer tab
      begin
         Block_Explorer_Tab.Refresh (Win.Explorer);
      exception
         when others => null;
      end;

      -- Exchange keys
      begin
         Exchange_Keys_Tab.Refresh_All (Win.Exchange_Keys);
      exception
         when others => null;
      end;

      -- Update toolbar address + balance from RPC
      begin
         declare
            R : RPC_Client.RPC_Result;
         begin
            RPC_Client.Call ("getwalletinfo", "{}", R);
            if R.Success then
               declare
                  Addr : constant String :=
                     RPC_Client.Extract_String
                       (R.Data (1 .. R.Len), "address");
                  Bal_Sat : constant Long_Long_Integer :=
                     RPC_Client.Extract_Number
                       (R.Data (1 .. R.Len), "balance");
               begin
                  if Addr'Length > 0 then
                     Win.Addr_Label.Set_Text (Addr);
                     Win.Overview.Address_Label.Set_Text (Addr);
                     Receive_Tab.Set_Address (Win.Receive, Addr);
                  end if;
                  if Bal_Sat > 0 then
                     declare
                        Whole : constant Long_Long_Integer := Bal_Sat / 1_000_000_000;
                        Frac  : constant Long_Long_Integer := Bal_Sat mod 1_000_000_000;
                        W_Str : constant String := Long_Long_Integer'Image (Whole);
                        F_Str : constant String := Long_Long_Integer'Image (Frac + 1_000_000_000);
                        --  F_Str will be " 1XXXXXXXXX", we take chars 3..11
                        Bal_Text : constant String :=
                           W_Str (2 .. W_Str'Last) & "." &
                           F_Str (3 .. F_Str'Last) & " OMNI";
                     begin
                        Win.Balance_Label.Set_Text (Bal_Text);
                        Win.Overview.Balance_Label.Set_Text (Bal_Text);
                        Win.Overview.Balance_Sat.Set_Text
                          (Long_Long_Integer'Image (Bal_Sat) & " SAT");
                        Win.Send.Balance_Label.Set_Text ("Balance: " & Bal_Text);
                     end;
                  end if;
               end;
            end if;
         end;
      exception
         when others => null;
      end;

      -- Update status bar
      begin
         declare
            Height : Natural;
            OK     : Boolean;
         begin
            RPC_Client.Get_Block_Height (Height, OK);
            if OK then
               Win.Height_Status.Set_Text
                 ("Block:" & Natural'Image (Height));
               Win.Status_Label.Set_Text ("Connected to node");
            else
               Win.Status_Label.Set_Text ("Node offline");
            end if;
         end;
      exception
         when others =>
            Win.Status_Label.Set_Text ("Node offline");
      end;

      -- Peer count
      begin
         declare
            R : RPC_Client.RPC_Result;
         begin
            RPC_Client.Get_Peer_List (R);
            if R.Success then
               declare
                  Count : constant Long_Long_Integer :=
                     RPC_Client.Extract_Number (R.Data (1 .. R.Len), "count");
               begin
                  Win.Peer_Status.Set_Text
                    ("Peers:" & Long_Long_Integer'Image (Count));
                  Win.Overview.Peer_Count.Set_Text
                    (Long_Long_Integer'Image (Count));
               end;
            end if;
         end;
      exception
         when others => null;
      end;
   exception
      when others => null;  -- never crash from refresh
   end Refresh_All;

end Main_Window;

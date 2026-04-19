-- ============================================================
--  Main_Window  --  OmniBus GtkAda main application window
--
--  Contains: menu bar, wallet toolbar, 10-tab notebook,
--            status bar, timer-based RPC refresh
-- ============================================================

pragma Ada_2022;

with Gtk.Window;
with Gtk.Box;
with Gtk.Notebook;
with Gtk.Label;
with Gtk.Combo_Box_Text;
with Gtk.Button;
with Gtk.Menu_Item;

with Overview_Tab;
with Wallet_Tab;
with Send_Tab;
with Receive_Tab;
with Transactions_Tab;
with Mining_Tab;
with Network_Tab;
with Block_Explorer_Tab;
with Console_Tab;
with Exchange_Keys_Tab;

package Main_Window
   with SPARK_Mode => Off
is

   type Main_Window_Record is record
      Window        : Gtk.Window.Gtk_Window;
      Main_Box      : Gtk.Box.Gtk_Box;
      Notebook      : Gtk.Notebook.Gtk_Notebook;

      -- Wallet toolbar
      Wallet_Combo  : Gtk.Combo_Box_Text.Gtk_Combo_Box_Text;
      Addr_Label    : Gtk.Label.Gtk_Label;
      Balance_Label : Gtk.Label.Gtk_Label;
      Lock_Btn      : Gtk.Button.Gtk_Button;

      -- Menu items
      Quit_Item     : Gtk.Menu_Item.Gtk_Menu_Item;

      -- Status bar
      Status_Label  : Gtk.Label.Gtk_Label;
      Height_Status : Gtk.Label.Gtk_Label;
      Peer_Status   : Gtk.Label.Gtk_Label;
      WS_Status     : Gtk.Label.Gtk_Label;

      -- Tabs
      Overview      : Overview_Tab.Overview_Tab_Record;
      Multi_Wallet  : Wallet_Tab.Wallet_Tab_Record;
      Send          : Send_Tab.Send_Tab_Record;
      Receive       : Receive_Tab.Receive_Tab_Record;
      Transactions  : Transactions_Tab.Transactions_Tab_Record;
      Mining        : Mining_Tab.Mining_Tab_Record;
      Network       : Network_Tab.Network_Tab_Record;
      Explorer      : Block_Explorer_Tab.Block_Explorer_Tab_Record;
      Console       : Console_Tab.Console_Tab_Record;
      Exchange_Keys : Exchange_Keys_Tab.Exchange_Keys_Tab_Record;
   end record;

   procedure Create (Win : out Main_Window_Record);

   procedure Show (Win : Main_Window_Record);

   type Main_Window_Access is access all Main_Window_Record;

   procedure Connect_Signals (Win_Ptr : Main_Window_Access);

   procedure Refresh_All (Win : in out Main_Window_Record);

end Main_Window;

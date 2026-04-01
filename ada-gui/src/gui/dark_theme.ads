-- ============================================================
--  Dark_Theme  --  OmniBus GTK3 CSS dark theme
--
--  Colors match the OmniBus design system:
--    bg-dark: #0d0f1a   bg-panel: #12141f   bg-card: #1a1d2e
--    border: #2a2d44    text: #e0e0f0       text-dim: #8888aa
--    accent: #7b61ff    teal: #00b3a4       red: #ff5555
-- ============================================================

pragma Ada_2022;

package Dark_Theme is

   CSS : constant String :=
      "/* OmniBus Dark Theme */" & ASCII.LF &

      --  Window / general
      "window, dialog {" & ASCII.LF &
      "  background-color: #0d0f1a;" & ASCII.LF &
      "  color: #e0e0f0;" & ASCII.LF &
      "}" & ASCII.LF &

      --  Header bar
      "headerbar {" & ASCII.LF &
      "  background-color: #12141f;" & ASCII.LF &
      "  border-bottom: 1px solid #2a2d44;" & ASCII.LF &
      "  color: #e0e0f0;" & ASCII.LF &
      "}" & ASCII.LF &

      --  Notebook (tabs)
      "notebook {" & ASCII.LF &
      "  background-color: #0d0f1a;" & ASCII.LF &
      "}" & ASCII.LF &
      "notebook header {" & ASCII.LF &
      "  background-color: #12141f;" & ASCII.LF &
      "  border-bottom: 1px solid #2a2d44;" & ASCII.LF &
      "}" & ASCII.LF &
      "notebook header tab {" & ASCII.LF &
      "  background-color: #12141f;" & ASCII.LF &
      "  color: #8888aa;" & ASCII.LF &
      "  padding: 6px 16px;" & ASCII.LF &
      "  border: none;" & ASCII.LF &
      "  border-bottom: 2px solid transparent;" & ASCII.LF &
      "}" & ASCII.LF &
      "notebook header tab:checked {" & ASCII.LF &
      "  color: #7b61ff;" & ASCII.LF &
      "  border-bottom: 2px solid #7b61ff;" & ASCII.LF &
      "  background-color: #1a1d2e;" & ASCII.LF &
      "}" & ASCII.LF &
      "notebook header tab:hover {" & ASCII.LF &
      "  color: #e0e0f0;" & ASCII.LF &
      "  background-color: rgba(122,97,255,0.08);" & ASCII.LF &
      "}" & ASCII.LF &
      "notebook stack {" & ASCII.LF &
      "  background-color: #0d0f1a;" & ASCII.LF &
      "}" & ASCII.LF &

      --  Labels
      "label {" & ASCII.LF &
      "  color: #e0e0f0;" & ASCII.LF &
      "}" & ASCII.LF &
      "label.dim {" & ASCII.LF &
      "  color: #8888aa;" & ASCII.LF &
      "}" & ASCII.LF &
      "label.accent {" & ASCII.LF &
      "  color: #7b61ff;" & ASCII.LF &
      "}" & ASCII.LF &
      "label.teal {" & ASCII.LF &
      "  color: #00b3a4;" & ASCII.LF &
      "}" & ASCII.LF &
      "label.balance {" & ASCII.LF &
      "  color: #00b3a4;" & ASCII.LF &
      "  font-size: 24px;" & ASCII.LF &
      "  font-weight: bold;" & ASCII.LF &
      "}" & ASCII.LF &
      "label.title {" & ASCII.LF &
      "  font-size: 18px;" & ASCII.LF &
      "  font-weight: bold;" & ASCII.LF &
      "  color: #e0e0f0;" & ASCII.LF &
      "}" & ASCII.LF &
      "label.mono {" & ASCII.LF &
      "  font-family: Consolas, monospace;" & ASCII.LF &
      "  color: #7b61ff;" & ASCII.LF &
      "}" & ASCII.LF &

      --  Entry (text input)
      "entry {" & ASCII.LF &
      "  background-color: #1a1d2e;" & ASCII.LF &
      "  color: #e0e0f0;" & ASCII.LF &
      "  border: 1px solid #2a2d44;" & ASCII.LF &
      "  border-radius: 4px;" & ASCII.LF &
      "  padding: 6px 10px;" & ASCII.LF &
      "  caret-color: #7b61ff;" & ASCII.LF &
      "}" & ASCII.LF &
      "entry:focus {" & ASCII.LF &
      "  border-color: #7b61ff;" & ASCII.LF &
      "}" & ASCII.LF &

      --  SpinButton
      "spinbutton {" & ASCII.LF &
      "  background-color: #1a1d2e;" & ASCII.LF &
      "  color: #e0e0f0;" & ASCII.LF &
      "  border: 1px solid #2a2d44;" & ASCII.LF &
      "  border-radius: 4px;" & ASCII.LF &
      "}" & ASCII.LF &
      "spinbutton entry {" & ASCII.LF &
      "  border: none;" & ASCII.LF &
      "}" & ASCII.LF &
      "spinbutton button {" & ASCII.LF &
      "  background-color: #1a1d2e;" & ASCII.LF &
      "  color: #8888aa;" & ASCII.LF &
      "  border: none;" & ASCII.LF &
      "}" & ASCII.LF &

      --  Buttons
      "button {" & ASCII.LF &
      "  background-color: #1a1d2e;" & ASCII.LF &
      "  color: #e0e0f0;" & ASCII.LF &
      "  border: 1px solid #2a2d44;" & ASCII.LF &
      "  border-radius: 4px;" & ASCII.LF &
      "  padding: 6px 14px;" & ASCII.LF &
      "}" & ASCII.LF &
      "button:hover {" & ASCII.LF &
      "  background-color: #2a2d44;" & ASCII.LF &
      "}" & ASCII.LF &
      "button.accent {" & ASCII.LF &
      "  background-color: #7b61ff;" & ASCII.LF &
      "  color: #ffffff;" & ASCII.LF &
      "  border-color: #7b61ff;" & ASCII.LF &
      "}" & ASCII.LF &
      "button.accent:hover {" & ASCII.LF &
      "  background-color: #8b71ff;" & ASCII.LF &
      "}" & ASCII.LF &
      "button.teal {" & ASCII.LF &
      "  background-color: #00b3a4;" & ASCII.LF &
      "  color: #ffffff;" & ASCII.LF &
      "  border-color: #00b3a4;" & ASCII.LF &
      "}" & ASCII.LF &
      "button.teal:hover {" & ASCII.LF &
      "  background-color: #00cdb8;" & ASCII.LF &
      "}" & ASCII.LF &
      "button.destructive {" & ASCII.LF &
      "  background-color: #ff5555;" & ASCII.LF &
      "  color: #ffffff;" & ASCII.LF &
      "  border-color: #ff5555;" & ASCII.LF &
      "}" & ASCII.LF &
      "button.destructive:hover {" & ASCII.LF &
      "  background-color: #ff7777;" & ASCII.LF &
      "}" & ASCII.LF &

      --  ComboBox
      "combobox, combobox button {" & ASCII.LF &
      "  background-color: #1a1d2e;" & ASCII.LF &
      "  color: #e0e0f0;" & ASCII.LF &
      "  border: 1px solid #2a2d44;" & ASCII.LF &
      "  border-radius: 4px;" & ASCII.LF &
      "}" & ASCII.LF &

      --  TreeView / ListView
      "treeview {" & ASCII.LF &
      "  background-color: #12141f;" & ASCII.LF &
      "  color: #e0e0f0;" & ASCII.LF &
      "}" & ASCII.LF &
      "treeview header button {" & ASCII.LF &
      "  background-color: #12141f;" & ASCII.LF &
      "  color: #8888aa;" & ASCII.LF &
      "  border-bottom: 1px solid #2a2d44;" & ASCII.LF &
      "  font-size: 11px;" & ASCII.LF &
      "  font-weight: bold;" & ASCII.LF &
      "  text-transform: uppercase;" & ASCII.LF &
      "  padding: 8px 12px;" & ASCII.LF &
      "}" & ASCII.LF &
      "treeview:selected {" & ASCII.LF &
      "  background-color: rgba(122,97,255,0.2);" & ASCII.LF &
      "  color: #e0e0f0;" & ASCII.LF &
      "}" & ASCII.LF &
      "treeview:hover {" & ASCII.LF &
      "  background-color: rgba(122,97,255,0.05);" & ASCII.LF &
      "}" & ASCII.LF &

      --  Scrolled window
      "scrolledwindow {" & ASCII.LF &
      "  background-color: #0d0f1a;" & ASCII.LF &
      "}" & ASCII.LF &
      "scrollbar {" & ASCII.LF &
      "  background-color: #12141f;" & ASCII.LF &
      "}" & ASCII.LF &
      "scrollbar slider {" & ASCII.LF &
      "  background-color: #2a2d44;" & ASCII.LF &
      "  border-radius: 4px;" & ASCII.LF &
      "  min-width: 6px;" & ASCII.LF &
      "  min-height: 6px;" & ASCII.LF &
      "}" & ASCII.LF &

      --  Progress bar
      "progressbar trough {" & ASCII.LF &
      "  background-color: #1a1d2e;" & ASCII.LF &
      "  border-radius: 4px;" & ASCII.LF &
      "}" & ASCII.LF &
      "progressbar progress {" & ASCII.LF &
      "  background-color: #7b61ff;" & ASCII.LF &
      "  border-radius: 4px;" & ASCII.LF &
      "}" & ASCII.LF &

      --  Menu bar
      "menubar {" & ASCII.LF &
      "  background-color: #12141f;" & ASCII.LF &
      "  color: #e0e0f0;" & ASCII.LF &
      "  border-bottom: 1px solid #2a2d44;" & ASCII.LF &
      "}" & ASCII.LF &
      "menubar > menuitem {" & ASCII.LF &
      "  color: #8888aa;" & ASCII.LF &
      "  padding: 4px 10px;" & ASCII.LF &
      "}" & ASCII.LF &
      "menubar > menuitem:hover {" & ASCII.LF &
      "  color: #e0e0f0;" & ASCII.LF &
      "  background-color: rgba(122,97,255,0.12);" & ASCII.LF &
      "}" & ASCII.LF &
      "menu {" & ASCII.LF &
      "  background-color: #1a1d2e;" & ASCII.LF &
      "  border: 1px solid #2a2d44;" & ASCII.LF &
      "  color: #e0e0f0;" & ASCII.LF &
      "}" & ASCII.LF &
      "menu menuitem {" & ASCII.LF &
      "  padding: 6px 16px;" & ASCII.LF &
      "}" & ASCII.LF &
      "menu menuitem:hover {" & ASCII.LF &
      "  background-color: rgba(122,97,255,0.12);" & ASCII.LF &
      "}" & ASCII.LF &

      --  Separator
      "separator {" & ASCII.LF &
      "  background-color: #2a2d44;" & ASCII.LF &
      "  min-height: 1px;" & ASCII.LF &
      "}" & ASCII.LF &

      --  Toolbar
      "toolbar {" & ASCII.LF &
      "  background-color: #0d0f1a;" & ASCII.LF &
      "  border-bottom: 1px solid #2a2d44;" & ASCII.LF &
      "  padding: 4px 8px;" & ASCII.LF &
      "}" & ASCII.LF &

      --  Frame (card-like container)
      "frame {" & ASCII.LF &
      "  background-color: #1a1d2e;" & ASCII.LF &
      "  border: 1px solid #2a2d44;" & ASCII.LF &
      "  border-radius: 6px;" & ASCII.LF &
      "}" & ASCII.LF &
      "frame > label {" & ASCII.LF &
      "  color: #8888aa;" & ASCII.LF &
      "  font-weight: bold;" & ASCII.LF &
      "}" & ASCII.LF &

      --  Statusbar
      ".statusbar {" & ASCII.LF &
      "  background-color: #12141f;" & ASCII.LF &
      "  border-top: 1px solid #2a2d44;" & ASCII.LF &
      "  color: #8888aa;" & ASCII.LF &
      "  padding: 2px 12px;" & ASCII.LF &
      "  font-size: 11px;" & ASCII.LF &
      "}" & ASCII.LF &

      --  Text view (console)
      "textview {" & ASCII.LF &
      "  background-color: #0a0c14;" & ASCII.LF &
      "  color: #00b3a4;" & ASCII.LF &
      "  font-family: Consolas, monospace;" & ASCII.LF &
      "  font-size: 12px;" & ASCII.LF &
      "}" & ASCII.LF &
      "textview text {" & ASCII.LF &
      "  background-color: #0a0c14;" & ASCII.LF &
      "  color: #00b3a4;" & ASCII.LF &
      "}" & ASCII.LF &

      --  Status pills
      ".pill-paid {" & ASCII.LF &
      "  background-color: rgba(0,179,164,0.15);" & ASCII.LF &
      "  color: #00b3a4;" & ASCII.LF &
      "  border-radius: 10px;" & ASCII.LF &
      "  padding: 2px 10px;" & ASCII.LF &
      "}" & ASCII.LF &
      ".pill-free {" & ASCII.LF &
      "  background-color: rgba(204,170,0,0.15);" & ASCII.LF &
      "  color: #ccaa00;" & ASCII.LF &
      "  border-radius: 10px;" & ASCII.LF &
      "  padding: 2px 10px;" & ASCII.LF &
      "}" & ASCII.LF &
      ".pill-notpaid {" & ASCII.LF &
      "  background-color: rgba(255,85,85,0.15);" & ASCII.LF &
      "  color: #ff5555;" & ASCII.LF &
      "  border-radius: 10px;" & ASCII.LF &
      "  padding: 2px 10px;" & ASCII.LF &
      "}" & ASCII.LF &

      --  SPARK badge
      ".spark-badge {" & ASCII.LF &
      "  background-color: rgba(0,179,164,0.1);" & ASCII.LF &
      "  color: #00b3a4;" & ASCII.LF &
      "  border-radius: 4px;" & ASCII.LF &
      "  padding: 2px 8px;" & ASCII.LF &
      "  font-size: 10px;" & ASCII.LF &
      "  font-weight: bold;" & ASCII.LF &
      "}" & ASCII.LF &

      --  Card (stat box)
      ".stat-card {" & ASCII.LF &
      "  background-color: #1a1d2e;" & ASCII.LF &
      "  border: 1px solid #2a2d44;" & ASCII.LF &
      "  border-radius: 8px;" & ASCII.LF &
      "  padding: 16px;" & ASCII.LF &
      "}" & ASCII.LF &
      ".stat-value {" & ASCII.LF &
      "  font-size: 20px;" & ASCII.LF &
      "  font-weight: bold;" & ASCII.LF &
      "  color: #7b61ff;" & ASCII.LF &
      "}" & ASCII.LF &
      ".stat-label {" & ASCII.LF &
      "  font-size: 11px;" & ASCII.LF &
      "  color: #8888aa;" & ASCII.LF &
      "  text-transform: uppercase;" & ASCII.LF &
      "}" & ASCII.LF;

end Dark_Theme;

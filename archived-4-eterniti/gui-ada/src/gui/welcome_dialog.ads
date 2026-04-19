-- ============================================================
--  Welcome_Dialog  --  Startup dialog: Create / Import / Connect
-- ============================================================

pragma Ada_2022;

package Welcome_Dialog
   with SPARK_Mode => Off
is

   type User_Choice is (Create_Wallet, Import_Wallet, Connect_Node, No_Choice);

   function Run return User_Choice;
   --  Show modal welcome dialog.  Returns user's selection.
   --  If user closes window without choosing, returns No_Choice.

end Welcome_Dialog;

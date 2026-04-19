pragma Warnings (Off);
pragma Ada_95;
pragma Source_File_Name (omnibus_vaultmain, Spec_File_Name => "b__omnibus_vault.ads");
pragma Source_File_Name (omnibus_vaultmain, Body_File_Name => "b__omnibus_vault.adb");
pragma Suppress (Overflow_Check);
with Ada.Exceptions;

package body omnibus_vaultmain is

   E095 : Short_Integer; pragma Import (Ada, E095, "system__os_lib_E");
   E029 : Short_Integer; pragma Import (Ada, E029, "ada__exceptions_E");
   E034 : Short_Integer; pragma Import (Ada, E034, "system__soft_links_E");
   E045 : Short_Integer; pragma Import (Ada, E045, "system__exception_table_E");
   E061 : Short_Integer; pragma Import (Ada, E061, "ada__containers_E");
   E091 : Short_Integer; pragma Import (Ada, E091, "ada__io_exceptions_E");
   E052 : Short_Integer; pragma Import (Ada, E052, "ada__numerics_E");
   E076 : Short_Integer; pragma Import (Ada, E076, "ada__strings_E");
   E078 : Short_Integer; pragma Import (Ada, E078, "ada__strings__maps_E");
   E081 : Short_Integer; pragma Import (Ada, E081, "ada__strings__maps__constants_E");
   E066 : Short_Integer; pragma Import (Ada, E066, "interfaces__c_E");
   E046 : Short_Integer; pragma Import (Ada, E046, "system__exceptions_E");
   E106 : Short_Integer; pragma Import (Ada, E106, "system__object_reader_E");
   E071 : Short_Integer; pragma Import (Ada, E071, "system__dwarf_lines_E");
   E041 : Short_Integer; pragma Import (Ada, E041, "system__soft_links__initialize_E");
   E060 : Short_Integer; pragma Import (Ada, E060, "system__traceback__symbolic_E");
   E126 : Short_Integer; pragma Import (Ada, E126, "ada__assertions_E");
   E130 : Short_Integer; pragma Import (Ada, E130, "ada__strings__utf_encoding_E");
   E138 : Short_Integer; pragma Import (Ada, E138, "ada__tags_E");
   E128 : Short_Integer; pragma Import (Ada, E128, "ada__strings__text_buffers_E");
   E171 : Short_Integer; pragma Import (Ada, E171, "interfaces__c__strings_E");
   E161 : Short_Integer; pragma Import (Ada, E161, "ada__streams_E");
   E214 : Short_Integer; pragma Import (Ada, E214, "system__file_control_block_E");
   E184 : Short_Integer; pragma Import (Ada, E184, "system__finalization_root_E");
   E182 : Short_Integer; pragma Import (Ada, E182, "ada__finalization_E");
   E211 : Short_Integer; pragma Import (Ada, E211, "system__file_io_E");
   E222 : Short_Integer; pragma Import (Ada, E222, "ada__streams__stream_io_E");
   E218 : Short_Integer; pragma Import (Ada, E218, "system__storage_pools_E");
   E196 : Short_Integer; pragma Import (Ada, E196, "ada__strings__unbounded_E");
   E148 : Short_Integer; pragma Import (Ada, E148, "ada__calendar_E");
   E177 : Short_Integer; pragma Import (Ada, E177, "ada__calendar__time_zones_E");
   E146 : Short_Integer; pragma Import (Ada, E146, "system__random_seed_E");
   E216 : Short_Integer; pragma Import (Ada, E216, "system__regexp_E");
   E173 : Short_Integer; pragma Import (Ada, E173, "ada__directories_E");
   E021 : Short_Integer; pragma Import (Ada, E021, "vault_types_E");
   E003 : Short_Integer; pragma Import (Ada, E003, "spark_bip32_E");
   E005 : Short_Integer; pragma Import (Ada, E005, "spark_mnemonic_E");
   E007 : Short_Integer; pragma Import (Ada, E007, "spark_secp256k1_E");
   E013 : Short_Integer; pragma Import (Ada, E013, "spark_transaction_E");
   E017 : Short_Integer; pragma Import (Ada, E017, "vault_crypto_E");
   E019 : Short_Integer; pragma Import (Ada, E019, "vault_storage_E");
   E015 : Short_Integer; pragma Import (Ada, E015, "vault_c_api_E");

   Sec_Default_Sized_Stacks : array (1 .. 1) of aliased System.Secondary_Stack.SS_Stack (System.Parameters.Runtime_Default_Sec_Stack_Size);

   Local_Priority_Specific_Dispatching : constant String := "";
   Local_Interrupt_States : constant String := "";

   Is_Elaborated : Boolean := False;

   procedure finalize_library is
   begin
      declare
         procedure F1;
         pragma Import (Ada, F1, "ada__directories__finalize_body");
      begin
         E173 := E173 - 1;
         if E173 = 0 then
            F1;
         end if;
      end;
      declare
         procedure F2;
         pragma Import (Ada, F2, "ada__directories__finalize_spec");
      begin
         if E173 = 0 then
            F2;
         end if;
      end;
      E216 := E216 - 1;
      declare
         procedure F3;
         pragma Import (Ada, F3, "system__regexp__finalize_spec");
      begin
         if E216 = 0 then
            F3;
         end if;
      end;
      E196 := E196 - 1;
      declare
         procedure F4;
         pragma Import (Ada, F4, "ada__strings__unbounded__finalize_spec");
      begin
         if E196 = 0 then
            F4;
         end if;
      end;
      E222 := E222 - 1;
      declare
         procedure F5;
         pragma Import (Ada, F5, "ada__streams__stream_io__finalize_spec");
      begin
         if E222 = 0 then
            F5;
         end if;
      end;
      declare
         procedure F6;
         pragma Import (Ada, F6, "system__file_io__finalize_body");
      begin
         E211 := E211 - 1;
         if E211 = 0 then
            F6;
         end if;
      end;
      declare
         procedure Reraise_Library_Exception_If_Any;
            pragma Import (Ada, Reraise_Library_Exception_If_Any, "__gnat_reraise_library_exception_if_any");
      begin
         Reraise_Library_Exception_If_Any;
      end;
   end finalize_library;

   procedure omnibus_vaultfinal is

      procedure Runtime_Finalize;
      pragma Import (C, Runtime_Finalize, "__gnat_runtime_finalize");

   begin
      if not Is_Elaborated then
         return;
      end if;
      Is_Elaborated := False;
      Runtime_Finalize;
      finalize_library;
   end omnibus_vaultfinal;

   type No_Param_Proc is access procedure;
   pragma Favor_Top_Level (No_Param_Proc);

   procedure omnibus_vaultinit is
      Main_Priority : Integer;
      pragma Import (C, Main_Priority, "__gl_main_priority");
      Time_Slice_Value : Integer;
      pragma Import (C, Time_Slice_Value, "__gl_time_slice_val");
      WC_Encoding : Character;
      pragma Import (C, WC_Encoding, "__gl_wc_encoding");
      Locking_Policy : Character;
      pragma Import (C, Locking_Policy, "__gl_locking_policy");
      Queuing_Policy : Character;
      pragma Import (C, Queuing_Policy, "__gl_queuing_policy");
      Task_Dispatching_Policy : Character;
      pragma Import (C, Task_Dispatching_Policy, "__gl_task_dispatching_policy");
      Priority_Specific_Dispatching : System.Address;
      pragma Import (C, Priority_Specific_Dispatching, "__gl_priority_specific_dispatching");
      Num_Specific_Dispatching : Integer;
      pragma Import (C, Num_Specific_Dispatching, "__gl_num_specific_dispatching");
      Main_CPU : Integer;
      pragma Import (C, Main_CPU, "__gl_main_cpu");
      Interrupt_States : System.Address;
      pragma Import (C, Interrupt_States, "__gl_interrupt_states");
      Num_Interrupt_States : Integer;
      pragma Import (C, Num_Interrupt_States, "__gl_num_interrupt_states");
      Unreserve_All_Interrupts : Integer;
      pragma Import (C, Unreserve_All_Interrupts, "__gl_unreserve_all_interrupts");
      Detect_Blocking : Integer;
      pragma Import (C, Detect_Blocking, "__gl_detect_blocking");
      Default_Stack_Size : Integer;
      pragma Import (C, Default_Stack_Size, "__gl_default_stack_size");
      Default_Secondary_Stack_Size : System.Parameters.Size_Type;
      pragma Import (C, Default_Secondary_Stack_Size, "__gnat_default_ss_size");
      Bind_Env_Addr : System.Address;
      pragma Import (C, Bind_Env_Addr, "__gl_bind_env_addr");
      Interrupts_Default_To_System : Integer;
      pragma Import (C, Interrupts_Default_To_System, "__gl_interrupts_default_to_system");

      procedure Runtime_Initialize (Install_Handler : Integer);
      pragma Import (C, Runtime_Initialize, "__gnat_runtime_initialize");

      Finalize_Library_Objects : No_Param_Proc;
      pragma Import (C, Finalize_Library_Objects, "__gnat_finalize_library_objects");
      Binder_Sec_Stacks_Count : Natural;
      pragma Import (Ada, Binder_Sec_Stacks_Count, "__gnat_binder_ss_count");
      Default_Sized_SS_Pool : System.Address;
      pragma Import (Ada, Default_Sized_SS_Pool, "__gnat_default_ss_pool");

   begin
      if Is_Elaborated then
         return;
      end if;
      Is_Elaborated := True;
      Main_Priority := -1;
      Time_Slice_Value := -1;
      WC_Encoding := 'b';
      Locking_Policy := ' ';
      Queuing_Policy := ' ';
      Task_Dispatching_Policy := ' ';
      Priority_Specific_Dispatching :=
        Local_Priority_Specific_Dispatching'Address;
      Num_Specific_Dispatching := 0;
      Main_CPU := -1;
      Interrupt_States := Local_Interrupt_States'Address;
      Num_Interrupt_States := 0;
      Unreserve_All_Interrupts := 0;
      Detect_Blocking := 0;
      Default_Stack_Size := -1;

      omnibus_vaultmain'Elab_Body;
      Default_Secondary_Stack_Size := System.Parameters.Runtime_Default_Sec_Stack_Size;
      Binder_Sec_Stacks_Count := 1;
      Default_Sized_SS_Pool := Sec_Default_Sized_Stacks'Address;

      Runtime_Initialize (1);

      if E029 = 0 then
         Ada.Exceptions'Elab_Spec;
      end if;
      if E034 = 0 then
         System.Soft_Links'Elab_Spec;
      end if;
      if E045 = 0 then
         System.Exception_Table'Elab_Body;
      end if;
      E045 := E045 + 1;
      if E061 = 0 then
         Ada.Containers'Elab_Spec;
      end if;
      E061 := E061 + 1;
      if E091 = 0 then
         Ada.Io_Exceptions'Elab_Spec;
      end if;
      E091 := E091 + 1;
      if E052 = 0 then
         Ada.Numerics'Elab_Spec;
      end if;
      E052 := E052 + 1;
      if E076 = 0 then
         Ada.Strings'Elab_Spec;
      end if;
      E076 := E076 + 1;
      if E078 = 0 then
         Ada.Strings.Maps'Elab_Spec;
      end if;
      E078 := E078 + 1;
      if E081 = 0 then
         Ada.Strings.Maps.Constants'Elab_Spec;
      end if;
      E081 := E081 + 1;
      if E066 = 0 then
         Interfaces.C'Elab_Spec;
      end if;
      E066 := E066 + 1;
      if E046 = 0 then
         System.Exceptions'Elab_Spec;
      end if;
      E046 := E046 + 1;
      if E106 = 0 then
         System.Object_Reader'Elab_Spec;
      end if;
      E106 := E106 + 1;
      if E071 = 0 then
         System.Dwarf_Lines'Elab_Spec;
      end if;
      E071 := E071 + 1;
      if E095 = 0 then
         System.Os_Lib'Elab_Body;
      end if;
      E095 := E095 + 1;
      if E041 = 0 then
         System.Soft_Links.Initialize'Elab_Body;
      end if;
      E041 := E041 + 1;
      E034 := E034 + 1;
      if E060 = 0 then
         System.Traceback.Symbolic'Elab_Body;
      end if;
      E060 := E060 + 1;
      E029 := E029 + 1;
      if E126 = 0 then
         Ada.Assertions'Elab_Spec;
      end if;
      E126 := E126 + 1;
      if E130 = 0 then
         Ada.Strings.Utf_Encoding'Elab_Spec;
      end if;
      E130 := E130 + 1;
      if E138 = 0 then
         Ada.Tags'Elab_Spec;
      end if;
      if E138 = 0 then
         Ada.Tags'Elab_Body;
      end if;
      E138 := E138 + 1;
      if E128 = 0 then
         Ada.Strings.Text_Buffers'Elab_Spec;
      end if;
      E128 := E128 + 1;
      if E171 = 0 then
         Interfaces.C.Strings'Elab_Spec;
      end if;
      E171 := E171 + 1;
      if E161 = 0 then
         Ada.Streams'Elab_Spec;
      end if;
      E161 := E161 + 1;
      if E214 = 0 then
         System.File_Control_Block'Elab_Spec;
      end if;
      E214 := E214 + 1;
      if E184 = 0 then
         System.Finalization_Root'Elab_Spec;
      end if;
      E184 := E184 + 1;
      if E182 = 0 then
         Ada.Finalization'Elab_Spec;
      end if;
      E182 := E182 + 1;
      if E211 = 0 then
         System.File_Io'Elab_Body;
      end if;
      E211 := E211 + 1;
      if E222 = 0 then
         Ada.Streams.Stream_Io'Elab_Spec;
      end if;
      E222 := E222 + 1;
      if E218 = 0 then
         System.Storage_Pools'Elab_Spec;
      end if;
      E218 := E218 + 1;
      if E196 = 0 then
         Ada.Strings.Unbounded'Elab_Spec;
      end if;
      E196 := E196 + 1;
      if E148 = 0 then
         Ada.Calendar'Elab_Spec;
      end if;
      if E148 = 0 then
         Ada.Calendar'Elab_Body;
      end if;
      E148 := E148 + 1;
      if E177 = 0 then
         Ada.Calendar.Time_Zones'Elab_Spec;
      end if;
      E177 := E177 + 1;
      if E146 = 0 then
         System.Random_Seed'Elab_Body;
      end if;
      E146 := E146 + 1;
      if E216 = 0 then
         System.Regexp'Elab_Spec;
      end if;
      E216 := E216 + 1;
      if E173 = 0 then
         Ada.Directories'Elab_Spec;
      end if;
      if E173 = 0 then
         Ada.Directories'Elab_Body;
      end if;
      E173 := E173 + 1;
      if E021 = 0 then
         Vault_Types'Elab_Spec;
      end if;
      E021 := E021 + 1;
      E003 := E003 + 1;
      if E005 = 0 then
         Spark_Mnemonic'Elab_Body;
      end if;
      E005 := E005 + 1;
      if E007 = 0 then
         Spark_Secp256k1'Elab_Body;
      end if;
      E007 := E007 + 1;
      E013 := E013 + 1;
      E017 := E017 + 1;
      if E019 = 0 then
         Vault_Storage'Elab_Body;
      end if;
      E019 := E019 + 1;
      E015 := E015 + 1;
   end omnibus_vaultinit;

--  BEGIN Object file/option list
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\qt-ada-hybrid\ada-vault\obj\bip39_words.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\qt-ada-hybrid\ada-vault\obj\spark_sha256.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\qt-ada-hybrid\ada-vault\obj\spark_sha512.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\qt-ada-hybrid\ada-vault\obj\vault_types.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\qt-ada-hybrid\ada-vault\obj\spark_bip32.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\qt-ada-hybrid\ada-vault\obj\spark_mnemonic.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\qt-ada-hybrid\ada-vault\obj\spark_secp256k1.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\qt-ada-hybrid\ada-vault\obj\spark_transaction.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\qt-ada-hybrid\ada-vault\obj\win32_crypt.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\qt-ada-hybrid\ada-vault\obj\vault_crypto.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\qt-ada-hybrid\ada-vault\obj\vault_storage.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\qt-ada-hybrid\ada-vault\obj\vault_c_api.o
   --   -LC:\Kits work\limaje de programare\OmniBus-BlockChainCore\qt-ada-hybrid\ada-vault\obj\
   --   -LC:/users/cazan/appdata/local/alire/cache/toolchains/gnat_native_15.2.1_346e2e00/lib/gcc/x86_64-w64-mingw32/15.2.0/adalib/
   --   -static
   --   -lgnat
   --   -Wl,--stack=0x2000000
--  END Object file/option list   

end omnibus_vaultmain;

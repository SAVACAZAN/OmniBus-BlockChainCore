pragma Warnings (Off);
pragma Ada_95;
with System;
with System.Parameters;
with System.Secondary_Stack;
package omnibus_vaultmain is

   procedure omnibus_vaultinit;
   pragma Export (C, omnibus_vaultinit, "omnibus_vaultinit");
   pragma Linker_Constructor (omnibus_vaultinit);

   procedure omnibus_vaultfinal;
   pragma Export (C, omnibus_vaultfinal, "omnibus_vaultfinal");
   pragma Linker_Destructor (omnibus_vaultfinal);

   type Version_32 is mod 2 ** 32;
   u00001 : constant Version_32 := 16#8d56150c#;
   pragma Export (C, u00001, "bip39_wordsS");
   u00002 : constant Version_32 := 16#2ca7c0aa#;
   pragma Export (C, u00002, "spark_bip32B");
   u00003 : constant Version_32 := 16#5ff0f515#;
   pragma Export (C, u00003, "spark_bip32S");
   u00004 : constant Version_32 := 16#9132e13d#;
   pragma Export (C, u00004, "spark_mnemonicB");
   u00005 : constant Version_32 := 16#9df74a41#;
   pragma Export (C, u00005, "spark_mnemonicS");
   u00006 : constant Version_32 := 16#d5e1f537#;
   pragma Export (C, u00006, "spark_secp256k1B");
   u00007 : constant Version_32 := 16#bb19a1ea#;
   pragma Export (C, u00007, "spark_secp256k1S");
   u00008 : constant Version_32 := 16#e18714cf#;
   pragma Export (C, u00008, "spark_sha256B");
   u00009 : constant Version_32 := 16#95cc5a5d#;
   pragma Export (C, u00009, "spark_sha256S");
   u00010 : constant Version_32 := 16#cbf907f1#;
   pragma Export (C, u00010, "spark_sha512B");
   u00011 : constant Version_32 := 16#a566fe75#;
   pragma Export (C, u00011, "spark_sha512S");
   u00012 : constant Version_32 := 16#df9483e3#;
   pragma Export (C, u00012, "spark_transactionB");
   u00013 : constant Version_32 := 16#de432c6b#;
   pragma Export (C, u00013, "spark_transactionS");
   u00014 : constant Version_32 := 16#be13cccb#;
   pragma Export (C, u00014, "vault_c_apiB");
   u00015 : constant Version_32 := 16#6ab70808#;
   pragma Export (C, u00015, "vault_c_apiS");
   u00016 : constant Version_32 := 16#c9305dff#;
   pragma Export (C, u00016, "vault_cryptoB");
   u00017 : constant Version_32 := 16#96b4bb56#;
   pragma Export (C, u00017, "vault_cryptoS");
   u00018 : constant Version_32 := 16#afee46aa#;
   pragma Export (C, u00018, "vault_storageB");
   u00019 : constant Version_32 := 16#b2b4b254#;
   pragma Export (C, u00019, "vault_storageS");
   u00020 : constant Version_32 := 16#a803cfca#;
   pragma Export (C, u00020, "vault_typesB");
   u00021 : constant Version_32 := 16#73c9ed24#;
   pragma Export (C, u00021, "vault_typesS");
   u00022 : constant Version_32 := 16#5edfb397#;
   pragma Export (C, u00022, "win32_cryptS");

   --  BEGIN ELABORATION ORDER
   --  ada%s
   --  ada.characters%s
   --  ada.characters.latin_1%s
   --  interfaces%s
   --  system%s
   --  system.atomic_operations%s
   --  system.io%s
   --  system.io%b
   --  system.parameters%s
   --  system.parameters%b
   --  system.crtl%s
   --  interfaces.c_streams%s
   --  interfaces.c_streams%b
   --  system.shared_bignums%s
   --  system.spark%s
   --  system.spark.cut_operations%s
   --  system.spark.cut_operations%b
   --  system.storage_elements%s
   --  system.img_address_32%s
   --  system.img_address_64%s
   --  system.return_stack%s
   --  system.stack_checking%s
   --  system.stack_checking%b
   --  system.string_hash%s
   --  system.string_hash%b
   --  system.htable%s
   --  system.htable%b
   --  system.strings%s
   --  system.strings%b
   --  system.traceback_entries%s
   --  system.traceback_entries%b
   --  system.unsigned_types%s
   --  system.wch_con%s
   --  system.wch_con%b
   --  system.wch_jis%s
   --  system.wch_jis%b
   --  system.wch_cnv%s
   --  system.wch_cnv%b
   --  system.concat_2%s
   --  system.concat_2%b
   --  system.concat_3%s
   --  system.concat_3%b
   --  system.traceback%s
   --  system.traceback%b
   --  ada.characters.handling%s
   --  system.atomic_operations.test_and_set%s
   --  system.case_util%s
   --  system.os_lib%s
   --  system.secondary_stack%s
   --  system.standard_library%s
   --  ada.exceptions%s
   --  system.exceptions_debug%s
   --  system.exceptions_debug%b
   --  system.soft_links%s
   --  system.val_util%s
   --  system.val_util%b
   --  system.val_llu%s
   --  system.val_lli%s
   --  system.wch_stw%s
   --  system.wch_stw%b
   --  ada.exceptions.last_chance_handler%s
   --  ada.exceptions.last_chance_handler%b
   --  ada.exceptions.traceback%s
   --  ada.exceptions.traceback%b
   --  system.address_image%s
   --  system.address_image%b
   --  system.bit_ops%s
   --  system.bit_ops%b
   --  system.bounded_strings%s
   --  system.bounded_strings%b
   --  system.case_util%b
   --  system.exception_table%s
   --  system.exception_table%b
   --  ada.containers%s
   --  ada.io_exceptions%s
   --  ada.numerics%s
   --  ada.numerics.big_numbers%s
   --  ada.strings%s
   --  ada.strings.maps%s
   --  ada.strings.maps%b
   --  ada.strings.maps.constants%s
   --  interfaces.c%s
   --  interfaces.c%b
   --  system.atomic_primitives%s
   --  system.atomic_primitives%b
   --  system.exceptions%s
   --  system.exceptions.machine%s
   --  system.exceptions.machine%b
   --  system.win32%s
   --  ada.characters.handling%b
   --  system.atomic_operations.test_and_set%b
   --  system.exception_traces%s
   --  system.exception_traces%b
   --  system.img_int%s
   --  system.img_uns%s
   --  system.memory%s
   --  system.memory%b
   --  system.mmap%s
   --  system.mmap.os_interface%s
   --  system.mmap.os_interface%b
   --  system.mmap%b
   --  system.object_reader%s
   --  system.object_reader%b
   --  system.dwarf_lines%s
   --  system.dwarf_lines%b
   --  system.os_lib%b
   --  system.secondary_stack%b
   --  system.soft_links.initialize%s
   --  system.soft_links.initialize%b
   --  system.soft_links%b
   --  system.standard_library%b
   --  system.traceback.symbolic%s
   --  system.traceback.symbolic%b
   --  ada.exceptions%b
   --  ada.assertions%s
   --  ada.assertions%b
   --  ada.strings.search%s
   --  ada.strings.search%b
   --  ada.strings.fixed%s
   --  ada.strings.fixed%b
   --  ada.strings.utf_encoding%s
   --  ada.strings.utf_encoding%b
   --  ada.strings.utf_encoding.strings%s
   --  ada.strings.utf_encoding.strings%b
   --  ada.strings.utf_encoding.wide_strings%s
   --  ada.strings.utf_encoding.wide_strings%b
   --  ada.strings.utf_encoding.wide_wide_strings%s
   --  ada.strings.utf_encoding.wide_wide_strings%b
   --  ada.tags%s
   --  ada.tags%b
   --  ada.strings.text_buffers%s
   --  ada.strings.text_buffers%b
   --  ada.strings.text_buffers.utils%s
   --  ada.strings.text_buffers.utils%b
   --  interfaces.c.strings%s
   --  interfaces.c.strings%b
   --  ada.environment_variables%s
   --  ada.environment_variables%b
   --  system.arith_64%s
   --  system.arith_64%b
   --  system.atomic_counters%s
   --  system.atomic_counters%b
   --  system.bignums%s
   --  system.bignums%b
   --  system.fat_flt%s
   --  system.fat_lflt%s
   --  system.fat_llf%s
   --  system.os_constants%s
   --  system.os_locks%s
   --  system.finalization_primitives%s
   --  system.finalization_primitives%b
   --  system.put_images%s
   --  system.put_images%b
   --  ada.streams%s
   --  ada.streams%b
   --  system.communication%s
   --  system.communication%b
   --  system.file_control_block%s
   --  system.finalization_root%s
   --  system.finalization_root%b
   --  ada.finalization%s
   --  ada.containers.helpers%s
   --  ada.containers.helpers%b
   --  system.file_io%s
   --  system.file_io%b
   --  ada.streams.stream_io%s
   --  ada.streams.stream_io%b
   --  system.storage_pools%s
   --  system.storage_pools%b
   --  system.stream_attributes%s
   --  system.stream_attributes.xdr%s
   --  system.stream_attributes.xdr%b
   --  system.stream_attributes%b
   --  ada.strings.unbounded%s
   --  ada.strings.unbounded%b
   --  system.task_lock%s
   --  system.task_lock%b
   --  system.val_fixed_64%s
   --  system.val_uns%s
   --  system.val_int%s
   --  system.win32.ext%s
   --  system.os_primitives%s
   --  system.os_primitives%b
   --  ada.calendar%s
   --  ada.calendar%b
   --  ada.calendar.time_zones%s
   --  ada.calendar.time_zones%b
   --  ada.calendar.formatting%s
   --  ada.calendar.formatting%b
   --  system.assertions%s
   --  system.assertions%b
   --  system.file_attributes%s
   --  system.random_seed%s
   --  system.random_seed%b
   --  system.random_numbers%s
   --  system.random_numbers%b
   --  system.regexp%s
   --  system.regexp%b
   --  ada.directories%s
   --  ada.directories.hierarchical_file_names%s
   --  ada.directories.validity%s
   --  ada.directories.validity%b
   --  ada.directories%b
   --  ada.directories.hierarchical_file_names%b
   --  bip39_words%s
   --  spark_sha256%s
   --  spark_sha256%b
   --  spark_sha512%s
   --  spark_sha512%b
   --  vault_types%s
   --  vault_types%b
   --  spark_bip32%s
   --  spark_bip32%b
   --  spark_mnemonic%s
   --  spark_mnemonic%b
   --  spark_secp256k1%s
   --  spark_secp256k1%b
   --  spark_transaction%s
   --  spark_transaction%b
   --  win32_crypt%s
   --  vault_crypto%s
   --  vault_crypto%b
   --  vault_storage%s
   --  vault_storage%b
   --  vault_c_api%s
   --  vault_c_api%b
   --  END ELABORATION ORDER

end omnibus_vaultmain;

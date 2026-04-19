pragma Warnings (Off);
pragma Ada_95;
pragma Source_File_Name (ada_main, Spec_File_Name => "b__omnibus_gtk_main.ads");
pragma Source_File_Name (ada_main, Body_File_Name => "b__omnibus_gtk_main.adb");
pragma Suppress (Overflow_Check);
with Ada.Exceptions;

package body ada_main is

   E074 : Short_Integer; pragma Import (Ada, E074, "system__os_lib_E");
   E011 : Short_Integer; pragma Import (Ada, E011, "ada__exceptions_E");
   E015 : Short_Integer; pragma Import (Ada, E015, "system__soft_links_E");
   E024 : Short_Integer; pragma Import (Ada, E024, "system__exception_table_E");
   E040 : Short_Integer; pragma Import (Ada, E040, "ada__containers_E");
   E070 : Short_Integer; pragma Import (Ada, E070, "ada__io_exceptions_E");
   E031 : Short_Integer; pragma Import (Ada, E031, "ada__numerics_E");
   E055 : Short_Integer; pragma Import (Ada, E055, "ada__strings_E");
   E057 : Short_Integer; pragma Import (Ada, E057, "ada__strings__maps_E");
   E060 : Short_Integer; pragma Import (Ada, E060, "ada__strings__maps__constants_E");
   E045 : Short_Integer; pragma Import (Ada, E045, "interfaces__c_E");
   E025 : Short_Integer; pragma Import (Ada, E025, "system__exceptions_E");
   E085 : Short_Integer; pragma Import (Ada, E085, "system__object_reader_E");
   E050 : Short_Integer; pragma Import (Ada, E050, "system__dwarf_lines_E");
   E017 : Short_Integer; pragma Import (Ada, E017, "system__soft_links__initialize_E");
   E039 : Short_Integer; pragma Import (Ada, E039, "system__traceback__symbolic_E");
   E145 : Short_Integer; pragma Import (Ada, E145, "ada__assertions_E");
   E107 : Short_Integer; pragma Import (Ada, E107, "ada__strings__utf_encoding_E");
   E115 : Short_Integer; pragma Import (Ada, E115, "ada__tags_E");
   E105 : Short_Integer; pragma Import (Ada, E105, "ada__strings__text_buffers_E");
   E239 : Short_Integer; pragma Import (Ada, E239, "gnat_E");
   E204 : Short_Integer; pragma Import (Ada, E204, "interfaces__c__strings_E");
   E123 : Short_Integer; pragma Import (Ada, E123, "ada__streams_E");
   E138 : Short_Integer; pragma Import (Ada, E138, "system__file_control_block_E");
   E134 : Short_Integer; pragma Import (Ada, E134, "system__finalization_root_E");
   E132 : Short_Integer; pragma Import (Ada, E132, "ada__finalization_E");
   E131 : Short_Integer; pragma Import (Ada, E131, "system__file_io_E");
   E206 : Short_Integer; pragma Import (Ada, E206, "ada__streams__stream_io_E");
   E200 : Short_Integer; pragma Import (Ada, E200, "system__storage_pools_E");
   E232 : Short_Integer; pragma Import (Ada, E232, "system__storage_pools__subpools_E");
   E186 : Short_Integer; pragma Import (Ada, E186, "ada__strings__unbounded_E");
   E158 : Short_Integer; pragma Import (Ada, E158, "ada__calendar_E");
   E169 : Short_Integer; pragma Import (Ada, E169, "ada__calendar__time_zones_E");
   E121 : Short_Integer; pragma Import (Ada, E121, "ada__text_io_E");
   E224 : Short_Integer; pragma Import (Ada, E224, "system__pool_global_E");
   E481 : Short_Integer; pragma Import (Ada, E481, "gnat__sockets_E");
   E484 : Short_Integer; pragma Import (Ada, E484, "gnat__sockets__poll_E");
   E488 : Short_Integer; pragma Import (Ada, E488, "gnat__sockets__thin_common_E");
   E486 : Short_Integer; pragma Import (Ada, E486, "gnat__sockets__thin_E");
   E198 : Short_Integer; pragma Import (Ada, E198, "system__regexp_E");
   E156 : Short_Integer; pragma Import (Ada, E156, "ada__directories_E");
   E219 : Short_Integer; pragma Import (Ada, E219, "glib_E");
   E222 : Short_Integer; pragma Import (Ada, E222, "gtkada__types_E");
   E213 : Short_Integer; pragma Import (Ada, E213, "vault_types_E");
   E294 : Short_Integer; pragma Import (Ada, E294, "gdk__frame_timings_E");
   E250 : Short_Integer; pragma Import (Ada, E250, "glib__glist_E");
   E300 : Short_Integer; pragma Import (Ada, E300, "gdk__visual_E");
   E252 : Short_Integer; pragma Import (Ada, E252, "glib__gslist_E");
   E443 : Short_Integer; pragma Import (Ada, E443, "glib__poll_E");
   E244 : Short_Integer; pragma Import (Ada, E244, "gtkada__c_E");
   E236 : Short_Integer; pragma Import (Ada, E236, "glib__object_E");
   E230 : Short_Integer; pragma Import (Ada, E230, "glib__type_conversion_hooks_E");
   E246 : Short_Integer; pragma Import (Ada, E246, "glib__types_E");
   E248 : Short_Integer; pragma Import (Ada, E248, "glib__values_E");
   E238 : Short_Integer; pragma Import (Ada, E238, "gtkada__bindings_E");
   E254 : Short_Integer; pragma Import (Ada, E254, "cairo_E");
   E261 : Short_Integer; pragma Import (Ada, E261, "cairo__region_E");
   E275 : Short_Integer; pragma Import (Ada, E275, "gdk__rectangle_E");
   E265 : Short_Integer; pragma Import (Ada, E265, "glib__generic_properties_E");
   E290 : Short_Integer; pragma Import (Ada, E290, "gdk__color_E");
   E278 : Short_Integer; pragma Import (Ada, E278, "gdk__rgba_E");
   E407 : Short_Integer; pragma Import (Ada, E407, "glib__key_file_E");
   E273 : Short_Integer; pragma Import (Ada, E273, "glib__properties_E");
   E271 : Short_Integer; pragma Import (Ada, E271, "gdk__device_tool_E");
   E361 : Short_Integer; pragma Import (Ada, E361, "gdk__drawing_context_E");
   E269 : Short_Integer; pragma Import (Ada, E269, "gdk__event_E");
   E445 : Short_Integer; pragma Import (Ada, E445, "glib__spawn_E");
   E441 : Short_Integer; pragma Import (Ada, E441, "glib__main_E");
   E306 : Short_Integer; pragma Import (Ada, E306, "glib__string_E");
   E304 : Short_Integer; pragma Import (Ada, E304, "glib__variant_E");
   E369 : Short_Integer; pragma Import (Ada, E369, "glib__g_icon_E");
   E457 : Short_Integer; pragma Import (Ada, E457, "gtk__actionable_E");
   E310 : Short_Integer; pragma Import (Ada, E310, "gtk__builder_E");
   E349 : Short_Integer; pragma Import (Ada, E349, "gtk__buildable_E");
   E381 : Short_Integer; pragma Import (Ada, E381, "gtk__cell_area_context_E");
   E397 : Short_Integer; pragma Import (Ada, E397, "gtk__css_section_E");
   E284 : Short_Integer; pragma Import (Ada, E284, "gtk__enums_E");
   E355 : Short_Integer; pragma Import (Ada, E355, "gtk__orientable_E");
   E409 : Short_Integer; pragma Import (Ada, E409, "gtk__paper_size_E");
   E405 : Short_Integer; pragma Import (Ada, E405, "gtk__page_setup_E");
   E415 : Short_Integer; pragma Import (Ada, E415, "gtk__print_settings_E");
   E318 : Short_Integer; pragma Import (Ada, E318, "gtk__target_entry_E");
   E316 : Short_Integer; pragma Import (Ada, E316, "gtk__target_list_E");
   E435 : Short_Integer; pragma Import (Ada, E435, "gtk__text_mark_E");
   E323 : Short_Integer; pragma Import (Ada, E323, "pango__enums_E");
   E343 : Short_Integer; pragma Import (Ada, E343, "pango__attributes_E");
   E327 : Short_Integer; pragma Import (Ada, E327, "pango__font_metrics_E");
   E329 : Short_Integer; pragma Import (Ada, E329, "pango__language_E");
   E325 : Short_Integer; pragma Import (Ada, E325, "pango__font_E");
   E421 : Short_Integer; pragma Import (Ada, E421, "gtk__text_attributes_E");
   E423 : Short_Integer; pragma Import (Ada, E423, "gtk__text_tag_E");
   E333 : Short_Integer; pragma Import (Ada, E333, "pango__font_face_E");
   E331 : Short_Integer; pragma Import (Ada, E331, "pango__font_family_E");
   E335 : Short_Integer; pragma Import (Ada, E335, "pango__fontset_E");
   E337 : Short_Integer; pragma Import (Ada, E337, "pango__matrix_E");
   E321 : Short_Integer; pragma Import (Ada, E321, "pango__context_E");
   E339 : Short_Integer; pragma Import (Ada, E339, "pango__font_map_E");
   E345 : Short_Integer; pragma Import (Ada, E345, "pango__tabs_E");
   E341 : Short_Integer; pragma Import (Ada, E341, "pango__layout_E");
   E411 : Short_Integer; pragma Import (Ada, E411, "gtk__print_context_E");
   E292 : Short_Integer; pragma Import (Ada, E292, "gdk__frame_clock_E");
   E439 : Short_Integer; pragma Import (Ada, E439, "gdk__monitor_E");
   E256 : Short_Integer; pragma Import (Ada, E256, "gdk__display_E");
   E363 : Short_Integer; pragma Import (Ada, E363, "gdk__glcontext_E");
   E296 : Short_Integer; pragma Import (Ada, E296, "gdk__pixbuf_E");
   E228 : Short_Integer; pragma Import (Ada, E228, "gdk__screen_E");
   E267 : Short_Integer; pragma Import (Ada, E267, "gdk__device_E");
   E263 : Short_Integer; pragma Import (Ada, E263, "gdk__drag_contexts_E");
   E359 : Short_Integer; pragma Import (Ada, E359, "gdk__window_E");
   E302 : Short_Integer; pragma Import (Ada, E302, "glib__action_group_E");
   E308 : Short_Integer; pragma Import (Ada, E308, "gtk__accel_group_E");
   E353 : Short_Integer; pragma Import (Ada, E353, "gtk__adjustment_E");
   E371 : Short_Integer; pragma Import (Ada, E371, "gtk__cell_editable_E");
   E373 : Short_Integer; pragma Import (Ada, E373, "gtk__editable_E");
   E375 : Short_Integer; pragma Import (Ada, E375, "gtk__entry_buffer_E");
   E393 : Short_Integer; pragma Import (Ada, E393, "gtk__icon_source_E");
   E413 : Short_Integer; pragma Import (Ada, E413, "gtk__print_operation_preview_E");
   E312 : Short_Integer; pragma Import (Ada, E312, "gtk__selection_data_E");
   E431 : Short_Integer; pragma Import (Ada, E431, "gtk__clipboard_E");
   E314 : Short_Integer; pragma Import (Ada, E314, "gtk__style_E");
   E427 : Short_Integer; pragma Import (Ada, E427, "gtk__scrollable_E");
   E419 : Short_Integer; pragma Import (Ada, E419, "gtk__text_iter_E");
   E437 : Short_Integer; pragma Import (Ada, E437, "gtk__text_tag_table_E");
   E387 : Short_Integer; pragma Import (Ada, E387, "gtk__tree_model_E");
   E288 : Short_Integer; pragma Import (Ada, E288, "gtk__widget_E");
   E385 : Short_Integer; pragma Import (Ada, E385, "gtk__cell_renderer_E");
   E383 : Short_Integer; pragma Import (Ada, E383, "gtk__cell_layout_E");
   E379 : Short_Integer; pragma Import (Ada, E379, "gtk__cell_area_E");
   E351 : Short_Integer; pragma Import (Ada, E351, "gtk__container_E");
   E365 : Short_Integer; pragma Import (Ada, E365, "gtk__bin_E");
   E347 : Short_Integer; pragma Import (Ada, E347, "gtk__box_E");
   E377 : Short_Integer; pragma Import (Ada, E377, "gtk__entry_completion_E");
   E399 : Short_Integer; pragma Import (Ada, E399, "gtk__misc_E");
   E401 : Short_Integer; pragma Import (Ada, E401, "gtk__notebook_E");
   E417 : Short_Integer; pragma Import (Ada, E417, "gtk__status_bar_E");
   E286 : Short_Integer; pragma Import (Ada, E286, "gtk__style_provider_E");
   E282 : Short_Integer; pragma Import (Ada, E282, "gtk__settings_E");
   E395 : Short_Integer; pragma Import (Ada, E395, "gtk__style_context_E");
   E391 : Short_Integer; pragma Import (Ada, E391, "gtk__icon_set_E");
   E389 : Short_Integer; pragma Import (Ada, E389, "gtk__image_E");
   E367 : Short_Integer; pragma Import (Ada, E367, "gtk__gentry_E");
   E433 : Short_Integer; pragma Import (Ada, E433, "gtk__text_child_anchor_E");
   E429 : Short_Integer; pragma Import (Ada, E429, "gtk__text_buffer_E");
   E425 : Short_Integer; pragma Import (Ada, E425, "gtk__text_view_E");
   E357 : Short_Integer; pragma Import (Ada, E357, "gtk__window_E");
   E280 : Short_Integer; pragma Import (Ada, E280, "gtk__dialog_E");
   E403 : Short_Integer; pragma Import (Ada, E403, "gtk__print_operation_E");
   E259 : Short_Integer; pragma Import (Ada, E259, "gtk__arguments_E");
   E465 : Short_Integer; pragma Import (Ada, E465, "glib__menu_model_E");
   E455 : Short_Integer; pragma Import (Ada, E455, "gtk__action_E");
   E459 : Short_Integer; pragma Import (Ada, E459, "gtk__activatable_E");
   E453 : Short_Integer; pragma Import (Ada, E453, "gtk__button_E");
   E499 : Short_Integer; pragma Import (Ada, E499, "gtk__cell_renderer_text_E");
   E447 : Short_Integer; pragma Import (Ada, E447, "gtk__css_provider_E");
   E501 : Short_Integer; pragma Import (Ada, E501, "gtk__frame_E");
   E507 : Short_Integer; pragma Import (Ada, E507, "gtk__grange_E");
   E535 : Short_Integer; pragma Import (Ada, E535, "gtk__grid_E");
   E449 : Short_Integer; pragma Import (Ada, E449, "gtk__main_E");
   E467 : Short_Integer; pragma Import (Ada, E467, "gtk__menu_item_E");
   E469 : Short_Integer; pragma Import (Ada, E469, "gtk__menu_shell_E");
   E463 : Short_Integer; pragma Import (Ada, E463, "gtk__menu_E");
   E461 : Short_Integer; pragma Import (Ada, E461, "gtk__label_E");
   E471 : Short_Integer; pragma Import (Ada, E471, "gtk__menu_bar_E");
   E541 : Short_Integer; pragma Import (Ada, E541, "gtk__progress_bar_E");
   E505 : Short_Integer; pragma Import (Ada, E505, "gtk__scrollbar_E");
   E503 : Short_Integer; pragma Import (Ada, E503, "gtk__scrolled_window_E");
   E473 : Short_Integer; pragma Import (Ada, E473, "gtk__separator_E");
   E475 : Short_Integer; pragma Import (Ada, E475, "gtk__spin_button_E");
   E521 : Short_Integer; pragma Import (Ada, E521, "gtk__tooltip_E");
   E513 : Short_Integer; pragma Import (Ada, E513, "gtk__tree_drag_dest_E");
   E515 : Short_Integer; pragma Import (Ada, E515, "gtk__tree_drag_source_E");
   E523 : Short_Integer; pragma Import (Ada, E523, "gtk__tree_selection_E");
   E517 : Short_Integer; pragma Import (Ada, E517, "gtk__tree_sortable_E");
   E511 : Short_Integer; pragma Import (Ada, E511, "gtk__list_store_E");
   E551 : Short_Integer; pragma Import (Ada, E551, "gtk__tree_store_E");
   E509 : Short_Integer; pragma Import (Ada, E509, "gtk__tree_view_column_E");
   E519 : Short_Integer; pragma Import (Ada, E519, "gtk__tree_view_E");
   E531 : Short_Integer; pragma Import (Ada, E531, "gtk__combo_box_E");
   E529 : Short_Integer; pragma Import (Ada, E529, "gtk__combo_box_text_E");
   E477 : Short_Integer; pragma Import (Ada, E477, "gui_helpers_E");
   E497 : Short_Integer; pragma Import (Ada, E497, "block_explorer_tab_E");
   E533 : Short_Integer; pragma Import (Ada, E533, "mining_tab_E");
   E537 : Short_Integer; pragma Import (Ada, E537, "network_tab_E");
   E543 : Short_Integer; pragma Import (Ada, E543, "receive_tab_E");
   E479 : Short_Integer; pragma Import (Ada, E479, "rpc_client_E");
   E525 : Short_Integer; pragma Import (Ada, E525, "console_tab_E");
   E539 : Short_Integer; pragma Import (Ada, E539, "overview_tab_E");
   E545 : Short_Integer; pragma Import (Ada, E545, "send_tab_E");
   E547 : Short_Integer; pragma Import (Ada, E547, "transactions_tab_E");
   E549 : Short_Integer; pragma Import (Ada, E549, "wallet_tab_E");
   E553 : Short_Integer; pragma Import (Ada, E553, "welcome_dialog_E");
   E210 : Short_Integer; pragma Import (Ada, E210, "vault_crypto_E");
   E154 : Short_Integer; pragma Import (Ada, E154, "vault_storage_E");
   E215 : Short_Integer; pragma Import (Ada, E215, "vault_pipe_client_E");
   E141 : Short_Integer; pragma Import (Ada, E141, "exchange_manager_E");
   E527 : Short_Integer; pragma Import (Ada, E527, "exchange_keys_tab_E");
   E451 : Short_Integer; pragma Import (Ada, E451, "main_window_E");

   Sec_Default_Sized_Stacks : array (1 .. 1) of aliased System.Secondary_Stack.SS_Stack (System.Parameters.Runtime_Default_Sec_Stack_Size);

   Local_Priority_Specific_Dispatching : constant String := "";
   Local_Interrupt_States : constant String := "";

   Is_Elaborated : Boolean := False;

   procedure finalize_library is
   begin
      E529 := E529 - 1;
      declare
         procedure F1;
         pragma Import (Ada, F1, "gtk__combo_box_text__finalize_spec");
      begin
         F1;
      end;
      E531 := E531 - 1;
      declare
         procedure F2;
         pragma Import (Ada, F2, "gtk__combo_box__finalize_spec");
      begin
         F2;
      end;
      E519 := E519 - 1;
      declare
         procedure F3;
         pragma Import (Ada, F3, "gtk__tree_view__finalize_spec");
      begin
         F3;
      end;
      E509 := E509 - 1;
      declare
         procedure F4;
         pragma Import (Ada, F4, "gtk__tree_view_column__finalize_spec");
      begin
         F4;
      end;
      E551 := E551 - 1;
      declare
         procedure F5;
         pragma Import (Ada, F5, "gtk__tree_store__finalize_spec");
      begin
         F5;
      end;
      E511 := E511 - 1;
      declare
         procedure F6;
         pragma Import (Ada, F6, "gtk__list_store__finalize_spec");
      begin
         F6;
      end;
      E523 := E523 - 1;
      declare
         procedure F7;
         pragma Import (Ada, F7, "gtk__tree_selection__finalize_spec");
      begin
         F7;
      end;
      E521 := E521 - 1;
      declare
         procedure F8;
         pragma Import (Ada, F8, "gtk__tooltip__finalize_spec");
      begin
         F8;
      end;
      E475 := E475 - 1;
      declare
         procedure F9;
         pragma Import (Ada, F9, "gtk__spin_button__finalize_spec");
      begin
         F9;
      end;
      E473 := E473 - 1;
      declare
         procedure F10;
         pragma Import (Ada, F10, "gtk__separator__finalize_spec");
      begin
         F10;
      end;
      E503 := E503 - 1;
      declare
         procedure F11;
         pragma Import (Ada, F11, "gtk__scrolled_window__finalize_spec");
      begin
         F11;
      end;
      E505 := E505 - 1;
      declare
         procedure F12;
         pragma Import (Ada, F12, "gtk__scrollbar__finalize_spec");
      begin
         F12;
      end;
      E541 := E541 - 1;
      declare
         procedure F13;
         pragma Import (Ada, F13, "gtk__progress_bar__finalize_spec");
      begin
         F13;
      end;
      E471 := E471 - 1;
      declare
         procedure F14;
         pragma Import (Ada, F14, "gtk__menu_bar__finalize_spec");
      begin
         F14;
      end;
      E461 := E461 - 1;
      declare
         procedure F15;
         pragma Import (Ada, F15, "gtk__label__finalize_spec");
      begin
         F15;
      end;
      E463 := E463 - 1;
      declare
         procedure F16;
         pragma Import (Ada, F16, "gtk__menu__finalize_spec");
      begin
         F16;
      end;
      E469 := E469 - 1;
      declare
         procedure F17;
         pragma Import (Ada, F17, "gtk__menu_shell__finalize_spec");
      begin
         F17;
      end;
      E467 := E467 - 1;
      declare
         procedure F18;
         pragma Import (Ada, F18, "gtk__menu_item__finalize_spec");
      begin
         F18;
      end;
      E535 := E535 - 1;
      declare
         procedure F19;
         pragma Import (Ada, F19, "gtk__grid__finalize_spec");
      begin
         F19;
      end;
      E507 := E507 - 1;
      declare
         procedure F20;
         pragma Import (Ada, F20, "gtk__grange__finalize_spec");
      begin
         F20;
      end;
      E501 := E501 - 1;
      declare
         procedure F21;
         pragma Import (Ada, F21, "gtk__frame__finalize_spec");
      begin
         F21;
      end;
      E447 := E447 - 1;
      declare
         procedure F22;
         pragma Import (Ada, F22, "gtk__css_provider__finalize_spec");
      begin
         F22;
      end;
      E499 := E499 - 1;
      declare
         procedure F23;
         pragma Import (Ada, F23, "gtk__cell_renderer_text__finalize_spec");
      begin
         F23;
      end;
      E453 := E453 - 1;
      declare
         procedure F24;
         pragma Import (Ada, F24, "gtk__button__finalize_spec");
      begin
         F24;
      end;
      E455 := E455 - 1;
      declare
         procedure F25;
         pragma Import (Ada, F25, "gtk__action__finalize_spec");
      begin
         F25;
      end;
      E465 := E465 - 1;
      declare
         procedure F26;
         pragma Import (Ada, F26, "glib__menu_model__finalize_spec");
      begin
         F26;
      end;
      E357 := E357 - 1;
      E288 := E288 - 1;
      E387 := E387 - 1;
      E425 := E425 - 1;
      E437 := E437 - 1;
      E429 := E429 - 1;
      E395 := E395 - 1;
      E314 := E314 - 1;
      E417 := E417 - 1;
      E403 := E403 - 1;
      E401 := E401 - 1;
      E367 := E367 - 1;
      E377 := E377 - 1;
      E375 := E375 - 1;
      E280 := E280 - 1;
      E351 := E351 - 1;
      E431 := E431 - 1;
      E385 := E385 - 1;
      E379 := E379 - 1;
      E353 := E353 - 1;
      E308 := E308 - 1;
      E439 := E439 - 1;
      E292 := E292 - 1;
      E263 := E263 - 1;
      E256 := E256 - 1;
      E267 := E267 - 1;
      declare
         procedure F27;
         pragma Import (Ada, F27, "gtk__print_operation__finalize_spec");
      begin
         F27;
      end;
      declare
         procedure F28;
         pragma Import (Ada, F28, "gtk__dialog__finalize_spec");
      begin
         F28;
      end;
      declare
         procedure F29;
         pragma Import (Ada, F29, "gtk__window__finalize_spec");
      begin
         F29;
      end;
      declare
         procedure F30;
         pragma Import (Ada, F30, "gtk__text_view__finalize_spec");
      begin
         F30;
      end;
      declare
         procedure F31;
         pragma Import (Ada, F31, "gtk__text_buffer__finalize_spec");
      begin
         F31;
      end;
      E433 := E433 - 1;
      declare
         procedure F32;
         pragma Import (Ada, F32, "gtk__text_child_anchor__finalize_spec");
      begin
         F32;
      end;
      declare
         procedure F33;
         pragma Import (Ada, F33, "gtk__gentry__finalize_spec");
      begin
         F33;
      end;
      E389 := E389 - 1;
      declare
         procedure F34;
         pragma Import (Ada, F34, "gtk__image__finalize_spec");
      begin
         F34;
      end;
      E391 := E391 - 1;
      declare
         procedure F35;
         pragma Import (Ada, F35, "gtk__icon_set__finalize_spec");
      begin
         F35;
      end;
      declare
         procedure F36;
         pragma Import (Ada, F36, "gtk__style_context__finalize_spec");
      begin
         F36;
      end;
      E282 := E282 - 1;
      declare
         procedure F37;
         pragma Import (Ada, F37, "gtk__settings__finalize_spec");
      begin
         F37;
      end;
      declare
         procedure F38;
         pragma Import (Ada, F38, "gtk__status_bar__finalize_spec");
      begin
         F38;
      end;
      declare
         procedure F39;
         pragma Import (Ada, F39, "gtk__notebook__finalize_spec");
      begin
         F39;
      end;
      E399 := E399 - 1;
      declare
         procedure F40;
         pragma Import (Ada, F40, "gtk__misc__finalize_spec");
      begin
         F40;
      end;
      declare
         procedure F41;
         pragma Import (Ada, F41, "gtk__entry_completion__finalize_spec");
      begin
         F41;
      end;
      E347 := E347 - 1;
      declare
         procedure F42;
         pragma Import (Ada, F42, "gtk__box__finalize_spec");
      begin
         F42;
      end;
      E365 := E365 - 1;
      declare
         procedure F43;
         pragma Import (Ada, F43, "gtk__bin__finalize_spec");
      begin
         F43;
      end;
      declare
         procedure F44;
         pragma Import (Ada, F44, "gtk__container__finalize_spec");
      begin
         F44;
      end;
      declare
         procedure F45;
         pragma Import (Ada, F45, "gtk__cell_area__finalize_spec");
      begin
         F45;
      end;
      declare
         procedure F46;
         pragma Import (Ada, F46, "gtk__cell_renderer__finalize_spec");
      begin
         F46;
      end;
      declare
         procedure F47;
         pragma Import (Ada, F47, "gtk__widget__finalize_spec");
      begin
         F47;
      end;
      declare
         procedure F48;
         pragma Import (Ada, F48, "gtk__tree_model__finalize_spec");
      begin
         F48;
      end;
      declare
         procedure F49;
         pragma Import (Ada, F49, "gtk__text_tag_table__finalize_spec");
      begin
         F49;
      end;
      declare
         procedure F50;
         pragma Import (Ada, F50, "gtk__style__finalize_spec");
      begin
         F50;
      end;
      declare
         procedure F51;
         pragma Import (Ada, F51, "gtk__clipboard__finalize_spec");
      begin
         F51;
      end;
      E312 := E312 - 1;
      declare
         procedure F52;
         pragma Import (Ada, F52, "gtk__selection_data__finalize_spec");
      begin
         F52;
      end;
      E393 := E393 - 1;
      declare
         procedure F53;
         pragma Import (Ada, F53, "gtk__icon_source__finalize_spec");
      begin
         F53;
      end;
      declare
         procedure F54;
         pragma Import (Ada, F54, "gtk__entry_buffer__finalize_spec");
      begin
         F54;
      end;
      declare
         procedure F55;
         pragma Import (Ada, F55, "gtk__adjustment__finalize_spec");
      begin
         F55;
      end;
      declare
         procedure F56;
         pragma Import (Ada, F56, "gtk__accel_group__finalize_spec");
      begin
         F56;
      end;
      declare
         procedure F57;
         pragma Import (Ada, F57, "gdk__drag_contexts__finalize_spec");
      begin
         F57;
      end;
      declare
         procedure F58;
         pragma Import (Ada, F58, "gdk__device__finalize_spec");
      begin
         F58;
      end;
      E228 := E228 - 1;
      declare
         procedure F59;
         pragma Import (Ada, F59, "gdk__screen__finalize_spec");
      begin
         F59;
      end;
      E296 := E296 - 1;
      declare
         procedure F60;
         pragma Import (Ada, F60, "gdk__pixbuf__finalize_spec");
      begin
         F60;
      end;
      E363 := E363 - 1;
      declare
         procedure F61;
         pragma Import (Ada, F61, "gdk__glcontext__finalize_spec");
      begin
         F61;
      end;
      declare
         procedure F62;
         pragma Import (Ada, F62, "gdk__display__finalize_spec");
      begin
         F62;
      end;
      declare
         procedure F63;
         pragma Import (Ada, F63, "gdk__monitor__finalize_spec");
      begin
         F63;
      end;
      declare
         procedure F64;
         pragma Import (Ada, F64, "gdk__frame_clock__finalize_spec");
      begin
         F64;
      end;
      E411 := E411 - 1;
      declare
         procedure F65;
         pragma Import (Ada, F65, "gtk__print_context__finalize_spec");
      begin
         F65;
      end;
      E341 := E341 - 1;
      declare
         procedure F66;
         pragma Import (Ada, F66, "pango__layout__finalize_spec");
      begin
         F66;
      end;
      E345 := E345 - 1;
      declare
         procedure F67;
         pragma Import (Ada, F67, "pango__tabs__finalize_spec");
      begin
         F67;
      end;
      E339 := E339 - 1;
      declare
         procedure F68;
         pragma Import (Ada, F68, "pango__font_map__finalize_spec");
      begin
         F68;
      end;
      E321 := E321 - 1;
      declare
         procedure F69;
         pragma Import (Ada, F69, "pango__context__finalize_spec");
      begin
         F69;
      end;
      E335 := E335 - 1;
      declare
         procedure F70;
         pragma Import (Ada, F70, "pango__fontset__finalize_spec");
      begin
         F70;
      end;
      E331 := E331 - 1;
      declare
         procedure F71;
         pragma Import (Ada, F71, "pango__font_family__finalize_spec");
      begin
         F71;
      end;
      E333 := E333 - 1;
      declare
         procedure F72;
         pragma Import (Ada, F72, "pango__font_face__finalize_spec");
      begin
         F72;
      end;
      E423 := E423 - 1;
      declare
         procedure F73;
         pragma Import (Ada, F73, "gtk__text_tag__finalize_spec");
      begin
         F73;
      end;
      E325 := E325 - 1;
      declare
         procedure F74;
         pragma Import (Ada, F74, "pango__font__finalize_spec");
      begin
         F74;
      end;
      E329 := E329 - 1;
      declare
         procedure F75;
         pragma Import (Ada, F75, "pango__language__finalize_spec");
      begin
         F75;
      end;
      E327 := E327 - 1;
      declare
         procedure F76;
         pragma Import (Ada, F76, "pango__font_metrics__finalize_spec");
      begin
         F76;
      end;
      E343 := E343 - 1;
      declare
         procedure F77;
         pragma Import (Ada, F77, "pango__attributes__finalize_spec");
      begin
         F77;
      end;
      E435 := E435 - 1;
      declare
         procedure F78;
         pragma Import (Ada, F78, "gtk__text_mark__finalize_spec");
      begin
         F78;
      end;
      E316 := E316 - 1;
      declare
         procedure F79;
         pragma Import (Ada, F79, "gtk__target_list__finalize_spec");
      begin
         F79;
      end;
      E415 := E415 - 1;
      declare
         procedure F80;
         pragma Import (Ada, F80, "gtk__print_settings__finalize_spec");
      begin
         F80;
      end;
      E405 := E405 - 1;
      declare
         procedure F81;
         pragma Import (Ada, F81, "gtk__page_setup__finalize_spec");
      begin
         F81;
      end;
      E409 := E409 - 1;
      declare
         procedure F82;
         pragma Import (Ada, F82, "gtk__paper_size__finalize_spec");
      begin
         F82;
      end;
      E397 := E397 - 1;
      declare
         procedure F83;
         pragma Import (Ada, F83, "gtk__css_section__finalize_spec");
      begin
         F83;
      end;
      E381 := E381 - 1;
      declare
         procedure F84;
         pragma Import (Ada, F84, "gtk__cell_area_context__finalize_spec");
      begin
         F84;
      end;
      E310 := E310 - 1;
      declare
         procedure F85;
         pragma Import (Ada, F85, "gtk__builder__finalize_spec");
      begin
         F85;
      end;
      E304 := E304 - 1;
      declare
         procedure F86;
         pragma Import (Ada, F86, "glib__variant__finalize_spec");
      begin
         F86;
      end;
      E361 := E361 - 1;
      declare
         procedure F87;
         pragma Import (Ada, F87, "gdk__drawing_context__finalize_spec");
      begin
         F87;
      end;
      E271 := E271 - 1;
      declare
         procedure F88;
         pragma Import (Ada, F88, "gdk__device_tool__finalize_spec");
      begin
         F88;
      end;
      E236 := E236 - 1;
      declare
         procedure F89;
         pragma Import (Ada, F89, "glib__object__finalize_spec");
      begin
         F89;
      end;
      E294 := E294 - 1;
      declare
         procedure F90;
         pragma Import (Ada, F90, "gdk__frame_timings__finalize_spec");
      begin
         F90;
      end;
      E219 := E219 - 1;
      declare
         procedure F91;
         pragma Import (Ada, F91, "glib__finalize_spec");
      begin
         F91;
      end;
      declare
         procedure F92;
         pragma Import (Ada, F92, "ada__directories__finalize_body");
      begin
         E156 := E156 - 1;
         F92;
      end;
      declare
         procedure F93;
         pragma Import (Ada, F93, "ada__directories__finalize_spec");
      begin
         F93;
      end;
      E198 := E198 - 1;
      declare
         procedure F94;
         pragma Import (Ada, F94, "system__regexp__finalize_spec");
      begin
         F94;
      end;
      declare
         procedure F95;
         pragma Import (Ada, F95, "gnat__sockets__finalize_body");
      begin
         E481 := E481 - 1;
         F95;
      end;
      declare
         procedure F96;
         pragma Import (Ada, F96, "gnat__sockets__finalize_spec");
      begin
         F96;
      end;
      E224 := E224 - 1;
      declare
         procedure F97;
         pragma Import (Ada, F97, "system__pool_global__finalize_spec");
      begin
         F97;
      end;
      E121 := E121 - 1;
      declare
         procedure F98;
         pragma Import (Ada, F98, "ada__text_io__finalize_spec");
      begin
         F98;
      end;
      E186 := E186 - 1;
      declare
         procedure F99;
         pragma Import (Ada, F99, "ada__strings__unbounded__finalize_spec");
      begin
         F99;
      end;
      E232 := E232 - 1;
      declare
         procedure F100;
         pragma Import (Ada, F100, "system__storage_pools__subpools__finalize_spec");
      begin
         F100;
      end;
      E206 := E206 - 1;
      declare
         procedure F101;
         pragma Import (Ada, F101, "ada__streams__stream_io__finalize_spec");
      begin
         F101;
      end;
      declare
         procedure F102;
         pragma Import (Ada, F102, "system__file_io__finalize_body");
      begin
         E131 := E131 - 1;
         F102;
      end;
      declare
         procedure Reraise_Library_Exception_If_Any;
            pragma Import (Ada, Reraise_Library_Exception_If_Any, "__gnat_reraise_library_exception_if_any");
      begin
         Reraise_Library_Exception_If_Any;
      end;
   end finalize_library;

   procedure adafinal is
      procedure s_stalib_adafinal;
      pragma Import (Ada, s_stalib_adafinal, "system__standard_library__adafinal");

      procedure Runtime_Finalize;
      pragma Import (C, Runtime_Finalize, "__gnat_runtime_finalize");

   begin
      if not Is_Elaborated then
         return;
      end if;
      Is_Elaborated := False;
      Runtime_Finalize;
      s_stalib_adafinal;
   end adafinal;

   type No_Param_Proc is access procedure;
   pragma Favor_Top_Level (No_Param_Proc);

   procedure adainit is
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

      ada_main'Elab_Body;
      Default_Secondary_Stack_Size := System.Parameters.Runtime_Default_Sec_Stack_Size;
      Binder_Sec_Stacks_Count := 1;
      Default_Sized_SS_Pool := Sec_Default_Sized_Stacks'Address;

      Runtime_Initialize (1);

      Finalize_Library_Objects := finalize_library'access;

      Ada.Exceptions'Elab_Spec;
      System.Soft_Links'Elab_Spec;
      System.Exception_Table'Elab_Body;
      E024 := E024 + 1;
      Ada.Containers'Elab_Spec;
      E040 := E040 + 1;
      Ada.Io_Exceptions'Elab_Spec;
      E070 := E070 + 1;
      Ada.Numerics'Elab_Spec;
      E031 := E031 + 1;
      Ada.Strings'Elab_Spec;
      E055 := E055 + 1;
      Ada.Strings.Maps'Elab_Spec;
      E057 := E057 + 1;
      Ada.Strings.Maps.Constants'Elab_Spec;
      E060 := E060 + 1;
      Interfaces.C'Elab_Spec;
      E045 := E045 + 1;
      System.Exceptions'Elab_Spec;
      E025 := E025 + 1;
      System.Object_Reader'Elab_Spec;
      E085 := E085 + 1;
      System.Dwarf_Lines'Elab_Spec;
      E050 := E050 + 1;
      System.Os_Lib'Elab_Body;
      E074 := E074 + 1;
      System.Soft_Links.Initialize'Elab_Body;
      E017 := E017 + 1;
      E015 := E015 + 1;
      System.Traceback.Symbolic'Elab_Body;
      E039 := E039 + 1;
      E011 := E011 + 1;
      Ada.Assertions'Elab_Spec;
      E145 := E145 + 1;
      Ada.Strings.Utf_Encoding'Elab_Spec;
      E107 := E107 + 1;
      Ada.Tags'Elab_Spec;
      Ada.Tags'Elab_Body;
      E115 := E115 + 1;
      Ada.Strings.Text_Buffers'Elab_Spec;
      E105 := E105 + 1;
      Gnat'Elab_Spec;
      E239 := E239 + 1;
      Interfaces.C.Strings'Elab_Spec;
      E204 := E204 + 1;
      Ada.Streams'Elab_Spec;
      E123 := E123 + 1;
      System.File_Control_Block'Elab_Spec;
      E138 := E138 + 1;
      System.Finalization_Root'Elab_Spec;
      E134 := E134 + 1;
      Ada.Finalization'Elab_Spec;
      E132 := E132 + 1;
      System.File_Io'Elab_Body;
      E131 := E131 + 1;
      Ada.Streams.Stream_Io'Elab_Spec;
      E206 := E206 + 1;
      System.Storage_Pools'Elab_Spec;
      E200 := E200 + 1;
      System.Storage_Pools.Subpools'Elab_Spec;
      E232 := E232 + 1;
      Ada.Strings.Unbounded'Elab_Spec;
      E186 := E186 + 1;
      Ada.Calendar'Elab_Spec;
      Ada.Calendar'Elab_Body;
      E158 := E158 + 1;
      Ada.Calendar.Time_Zones'Elab_Spec;
      E169 := E169 + 1;
      Ada.Text_Io'Elab_Spec;
      Ada.Text_Io'Elab_Body;
      E121 := E121 + 1;
      System.Pool_Global'Elab_Spec;
      E224 := E224 + 1;
      Gnat.Sockets'Elab_Spec;
      Gnat.Sockets.Thin_Common'Elab_Spec;
      E488 := E488 + 1;
      Gnat.Sockets.Thin'Elab_Body;
      E486 := E486 + 1;
      Gnat.Sockets'Elab_Body;
      E481 := E481 + 1;
      E484 := E484 + 1;
      System.Regexp'Elab_Spec;
      E198 := E198 + 1;
      Ada.Directories'Elab_Spec;
      Ada.Directories'Elab_Body;
      E156 := E156 + 1;
      Glib'Elab_Spec;
      Gtkada.Types'Elab_Spec;
      E222 := E222 + 1;
      E219 := E219 + 1;
      Vault_Types'Elab_Spec;
      E213 := E213 + 1;
      Gdk.Frame_Timings'Elab_Spec;
      Gdk.Frame_Timings'Elab_Body;
      E294 := E294 + 1;
      E250 := E250 + 1;
      Gdk.Visual'Elab_Body;
      E300 := E300 + 1;
      E252 := E252 + 1;
      E443 := E443 + 1;
      E244 := E244 + 1;
      Glib.Object'Elab_Spec;
      E230 := E230 + 1;
      Glib.Values'Elab_Body;
      E248 := E248 + 1;
      E238 := E238 + 1;
      Glib.Object'Elab_Body;
      E236 := E236 + 1;
      E246 := E246 + 1;
      E254 := E254 + 1;
      E261 := E261 + 1;
      E275 := E275 + 1;
      Glib.Generic_Properties'Elab_Spec;
      Glib.Generic_Properties'Elab_Body;
      E265 := E265 + 1;
      Gdk.Color'Elab_Spec;
      E290 := E290 + 1;
      E278 := E278 + 1;
      E407 := E407 + 1;
      E273 := E273 + 1;
      Gdk.Device_Tool'Elab_Spec;
      Gdk.Device_Tool'Elab_Body;
      E271 := E271 + 1;
      Gdk.Drawing_Context'Elab_Spec;
      Gdk.Drawing_Context'Elab_Body;
      E361 := E361 + 1;
      E269 := E269 + 1;
      E445 := E445 + 1;
      E441 := E441 + 1;
      E306 := E306 + 1;
      Glib.Variant'Elab_Spec;
      Glib.Variant'Elab_Body;
      E304 := E304 + 1;
      E369 := E369 + 1;
      Gtk.Actionable'Elab_Spec;
      E457 := E457 + 1;
      Gtk.Builder'Elab_Spec;
      Gtk.Builder'Elab_Body;
      E310 := E310 + 1;
      E349 := E349 + 1;
      Gtk.Cell_Area_Context'Elab_Spec;
      Gtk.Cell_Area_Context'Elab_Body;
      E381 := E381 + 1;
      Gtk.Css_Section'Elab_Spec;
      Gtk.Css_Section'Elab_Body;
      E397 := E397 + 1;
      E284 := E284 + 1;
      Gtk.Orientable'Elab_Spec;
      E355 := E355 + 1;
      Gtk.Paper_Size'Elab_Spec;
      Gtk.Paper_Size'Elab_Body;
      E409 := E409 + 1;
      Gtk.Page_Setup'Elab_Spec;
      Gtk.Page_Setup'Elab_Body;
      E405 := E405 + 1;
      Gtk.Print_Settings'Elab_Spec;
      Gtk.Print_Settings'Elab_Body;
      E415 := E415 + 1;
      E318 := E318 + 1;
      Gtk.Target_List'Elab_Spec;
      Gtk.Target_List'Elab_Body;
      E316 := E316 + 1;
      Gtk.Text_Mark'Elab_Spec;
      Gtk.Text_Mark'Elab_Body;
      E435 := E435 + 1;
      E323 := E323 + 1;
      Pango.Attributes'Elab_Spec;
      Pango.Attributes'Elab_Body;
      E343 := E343 + 1;
      Pango.Font_Metrics'Elab_Spec;
      Pango.Font_Metrics'Elab_Body;
      E327 := E327 + 1;
      Pango.Language'Elab_Spec;
      Pango.Language'Elab_Body;
      E329 := E329 + 1;
      Pango.Font'Elab_Spec;
      Pango.Font'Elab_Body;
      E325 := E325 + 1;
      E421 := E421 + 1;
      Gtk.Text_Tag'Elab_Spec;
      Gtk.Text_Tag'Elab_Body;
      E423 := E423 + 1;
      Pango.Font_Face'Elab_Spec;
      Pango.Font_Face'Elab_Body;
      E333 := E333 + 1;
      Pango.Font_Family'Elab_Spec;
      Pango.Font_Family'Elab_Body;
      E331 := E331 + 1;
      Pango.Fontset'Elab_Spec;
      Pango.Fontset'Elab_Body;
      E335 := E335 + 1;
      E337 := E337 + 1;
      Pango.Context'Elab_Spec;
      Pango.Context'Elab_Body;
      E321 := E321 + 1;
      Pango.Font_Map'Elab_Spec;
      Pango.Font_Map'Elab_Body;
      E339 := E339 + 1;
      Pango.Tabs'Elab_Spec;
      Pango.Tabs'Elab_Body;
      E345 := E345 + 1;
      Pango.Layout'Elab_Spec;
      Pango.Layout'Elab_Body;
      E341 := E341 + 1;
      Gtk.Print_Context'Elab_Spec;
      Gtk.Print_Context'Elab_Body;
      E411 := E411 + 1;
      Gdk.Frame_Clock'Elab_Spec;
      Gdk.Monitor'Elab_Spec;
      Gdk.Display'Elab_Spec;
      Gdk.Glcontext'Elab_Spec;
      Gdk.Glcontext'Elab_Body;
      E363 := E363 + 1;
      Gdk.Pixbuf'Elab_Spec;
      E296 := E296 + 1;
      Gdk.Screen'Elab_Spec;
      Gdk.Screen'Elab_Body;
      E228 := E228 + 1;
      Gdk.Device'Elab_Spec;
      Gdk.Drag_Contexts'Elab_Spec;
      Gdk.Window'Elab_Spec;
      E359 := E359 + 1;
      Gtk.Accel_Group'Elab_Spec;
      Gtk.Adjustment'Elab_Spec;
      Gtk.Cell_Editable'Elab_Spec;
      Gtk.Entry_Buffer'Elab_Spec;
      Gtk.Icon_Source'Elab_Spec;
      Gtk.Icon_Source'Elab_Body;
      E393 := E393 + 1;
      Gtk.Selection_Data'Elab_Spec;
      Gtk.Selection_Data'Elab_Body;
      E312 := E312 + 1;
      Gtk.Clipboard'Elab_Spec;
      Gtk.Style'Elab_Spec;
      Gtk.Scrollable'Elab_Spec;
      E427 := E427 + 1;
      E419 := E419 + 1;
      Gtk.Text_Tag_Table'Elab_Spec;
      Gtk.Tree_Model'Elab_Spec;
      Gtk.Widget'Elab_Spec;
      Gtk.Cell_Renderer'Elab_Spec;
      E383 := E383 + 1;
      Gtk.Cell_Area'Elab_Spec;
      Gtk.Container'Elab_Spec;
      Gtk.Bin'Elab_Spec;
      Gtk.Bin'Elab_Body;
      E365 := E365 + 1;
      Gtk.Box'Elab_Spec;
      Gtk.Box'Elab_Body;
      E347 := E347 + 1;
      Gtk.Entry_Completion'Elab_Spec;
      Gtk.Misc'Elab_Spec;
      Gtk.Misc'Elab_Body;
      E399 := E399 + 1;
      Gtk.Notebook'Elab_Spec;
      Gtk.Status_Bar'Elab_Spec;
      E286 := E286 + 1;
      Gtk.Settings'Elab_Spec;
      Gtk.Settings'Elab_Body;
      E282 := E282 + 1;
      Gtk.Style_Context'Elab_Spec;
      Gtk.Icon_Set'Elab_Spec;
      Gtk.Icon_Set'Elab_Body;
      E391 := E391 + 1;
      Gtk.Image'Elab_Spec;
      Gtk.Image'Elab_Body;
      E389 := E389 + 1;
      Gtk.Gentry'Elab_Spec;
      Gtk.Text_Child_Anchor'Elab_Spec;
      Gtk.Text_Child_Anchor'Elab_Body;
      E433 := E433 + 1;
      Gtk.Text_Buffer'Elab_Spec;
      Gtk.Text_View'Elab_Spec;
      Gtk.Window'Elab_Spec;
      Gtk.Dialog'Elab_Spec;
      Gtk.Print_Operation'Elab_Spec;
      E259 := E259 + 1;
      Gdk.Device'Elab_Body;
      E267 := E267 + 1;
      Gdk.Display'Elab_Body;
      E256 := E256 + 1;
      Gdk.Drag_Contexts'Elab_Body;
      E263 := E263 + 1;
      Gdk.Frame_Clock'Elab_Body;
      E292 := E292 + 1;
      Gdk.Monitor'Elab_Body;
      E439 := E439 + 1;
      E302 := E302 + 1;
      Gtk.Accel_Group'Elab_Body;
      E308 := E308 + 1;
      Gtk.Adjustment'Elab_Body;
      E353 := E353 + 1;
      Gtk.Cell_Area'Elab_Body;
      E379 := E379 + 1;
      E371 := E371 + 1;
      Gtk.Cell_Renderer'Elab_Body;
      E385 := E385 + 1;
      Gtk.Clipboard'Elab_Body;
      E431 := E431 + 1;
      Gtk.Container'Elab_Body;
      E351 := E351 + 1;
      Gtk.Dialog'Elab_Body;
      E280 := E280 + 1;
      E373 := E373 + 1;
      Gtk.Entry_Buffer'Elab_Body;
      E375 := E375 + 1;
      Gtk.Entry_Completion'Elab_Body;
      E377 := E377 + 1;
      Gtk.Gentry'Elab_Body;
      E367 := E367 + 1;
      Gtk.Notebook'Elab_Body;
      E401 := E401 + 1;
      Gtk.Print_Operation'Elab_Body;
      E403 := E403 + 1;
      E413 := E413 + 1;
      Gtk.Status_Bar'Elab_Body;
      E417 := E417 + 1;
      Gtk.Style'Elab_Body;
      E314 := E314 + 1;
      Gtk.Style_Context'Elab_Body;
      E395 := E395 + 1;
      Gtk.Text_Buffer'Elab_Body;
      E429 := E429 + 1;
      Gtk.Text_Tag_Table'Elab_Body;
      E437 := E437 + 1;
      Gtk.Text_View'Elab_Body;
      E425 := E425 + 1;
      Gtk.Tree_Model'Elab_Body;
      E387 := E387 + 1;
      Gtk.Widget'Elab_Body;
      E288 := E288 + 1;
      Gtk.Window'Elab_Body;
      E357 := E357 + 1;
      Glib.Menu_Model'Elab_Spec;
      Glib.Menu_Model'Elab_Body;
      E465 := E465 + 1;
      Gtk.Action'Elab_Spec;
      Gtk.Action'Elab_Body;
      E455 := E455 + 1;
      Gtk.Activatable'Elab_Spec;
      E459 := E459 + 1;
      Gtk.Button'Elab_Spec;
      Gtk.Button'Elab_Body;
      E453 := E453 + 1;
      Gtk.Cell_Renderer_Text'Elab_Spec;
      Gtk.Cell_Renderer_Text'Elab_Body;
      E499 := E499 + 1;
      Gtk.Css_Provider'Elab_Spec;
      Gtk.Css_Provider'Elab_Body;
      E447 := E447 + 1;
      Gtk.Frame'Elab_Spec;
      Gtk.Frame'Elab_Body;
      E501 := E501 + 1;
      Gtk.Grange'Elab_Spec;
      Gtk.Grange'Elab_Body;
      E507 := E507 + 1;
      Gtk.Grid'Elab_Spec;
      Gtk.Grid'Elab_Body;
      E535 := E535 + 1;
      E449 := E449 + 1;
      Gtk.Menu_Item'Elab_Spec;
      Gtk.Menu_Item'Elab_Body;
      E467 := E467 + 1;
      Gtk.Menu_Shell'Elab_Spec;
      Gtk.Menu_Shell'Elab_Body;
      E469 := E469 + 1;
      Gtk.Menu'Elab_Spec;
      Gtk.Menu'Elab_Body;
      E463 := E463 + 1;
      Gtk.Label'Elab_Spec;
      Gtk.Label'Elab_Body;
      E461 := E461 + 1;
      Gtk.Menu_Bar'Elab_Spec;
      Gtk.Menu_Bar'Elab_Body;
      E471 := E471 + 1;
      Gtk.Progress_Bar'Elab_Spec;
      Gtk.Progress_Bar'Elab_Body;
      E541 := E541 + 1;
      Gtk.Scrollbar'Elab_Spec;
      Gtk.Scrollbar'Elab_Body;
      E505 := E505 + 1;
      Gtk.Scrolled_Window'Elab_Spec;
      Gtk.Scrolled_Window'Elab_Body;
      E503 := E503 + 1;
      Gtk.Separator'Elab_Spec;
      Gtk.Separator'Elab_Body;
      E473 := E473 + 1;
      Gtk.Spin_Button'Elab_Spec;
      Gtk.Spin_Button'Elab_Body;
      E475 := E475 + 1;
      Gtk.Tooltip'Elab_Spec;
      Gtk.Tooltip'Elab_Body;
      E521 := E521 + 1;
      E513 := E513 + 1;
      E515 := E515 + 1;
      Gtk.Tree_Selection'Elab_Spec;
      Gtk.Tree_Selection'Elab_Body;
      E523 := E523 + 1;
      E517 := E517 + 1;
      Gtk.List_Store'Elab_Spec;
      Gtk.List_Store'Elab_Body;
      E511 := E511 + 1;
      Gtk.Tree_Store'Elab_Spec;
      Gtk.Tree_Store'Elab_Body;
      E551 := E551 + 1;
      Gtk.Tree_View_Column'Elab_Spec;
      Gtk.Tree_View_Column'Elab_Body;
      E509 := E509 + 1;
      Gtk.Tree_View'Elab_Spec;
      Gtk.Tree_View'Elab_Body;
      E519 := E519 + 1;
      Gtk.Combo_Box'Elab_Spec;
      Gtk.Combo_Box'Elab_Body;
      E531 := E531 + 1;
      Gtk.Combo_Box_Text'Elab_Spec;
      Gtk.Combo_Box_Text'Elab_Body;
      E529 := E529 + 1;
      E477 := E477 + 1;
      E497 := E497 + 1;
      E533 := E533 + 1;
      E537 := E537 + 1;
      E543 := E543 + 1;
      E479 := E479 + 1;
      E525 := E525 + 1;
      E539 := E539 + 1;
      E545 := E545 + 1;
      E547 := E547 + 1;
      E549 := E549 + 1;
      E553 := E553 + 1;
      E210 := E210 + 1;
      Vault_Storage'Elab_Body;
      E154 := E154 + 1;
      E215 := E215 + 1;
      E141 := E141 + 1;
      E527 := E527 + 1;
      E451 := E451 + 1;
   end adainit;

   procedure Ada_Main_Program;
   pragma Import (Ada, Ada_Main_Program, "_ada_omnibus_gtk_main");

   function main
     (argc : Integer;
      argv : System.Address;
      envp : System.Address)
      return Integer
   is
      procedure Initialize (Addr : System.Address);
      pragma Import (C, Initialize, "__gnat_initialize");

      procedure Finalize;
      pragma Import (C, Finalize, "__gnat_finalize");
      SEH : aliased array (1 .. 2) of Integer;

      Ensure_Reference : aliased System.Address := Ada_Main_Program_Name'Address;
      pragma Volatile (Ensure_Reference);

   begin
      if gnat_argc = 0 then
         gnat_argc := argc;
         gnat_argv := argv;
      end if;
      gnat_envp := envp;

      Initialize (SEH'Address);
      adainit;
      Ada_Main_Program;
      adafinal;
      Finalize;
      return (gnat_exit_status);
   end;

--  BEGIN Object file/option list
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\ada-gui\obj\vault_types.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\ada-gui\obj\dark_theme.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\ada-gui\obj\gui_helpers.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\ada-gui\obj\block_explorer_tab.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\ada-gui\obj\mining_tab.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\ada-gui\obj\network_tab.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\ada-gui\obj\receive_tab.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\ada-gui\obj\rpc_client.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\ada-gui\obj\console_tab.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\ada-gui\obj\overview_tab.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\ada-gui\obj\send_tab.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\ada-gui\obj\transactions_tab.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\ada-gui\obj\wallet_tab.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\ada-gui\obj\welcome_dialog.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\ada-gui\obj\win32_crypt.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\ada-gui\obj\vault_crypto.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\ada-gui\obj\vault_storage.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\ada-gui\obj\win32_pipes.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\ada-gui\obj\vault_pipe_client.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\ada-gui\obj\exchange_manager.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\ada-gui\obj\exchange_keys_tab.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\ada-gui\obj\main_window.o
   --   C:\Kits work\limaje de programare\OmniBus-BlockChainCore\ada-gui\obj\omnibus_gtk_main.o
   --   -LC:\Kits work\limaje de programare\OmniBus-BlockChainCore\ada-gui\obj\
   --   -LC:\Kits work\limaje de programare\OmniBus-BlockChainCore\ada-gui\obj\
   --   -LC:\Users\cazan\AppData\Local\alire\cache\builds\gtkada_26.0.0_489d17d3\9bbd709b0510e269c7ceb000a77391dbd13357758175001299c6ff93ca07457e\src\lib\gtkada\relocatable\
   --   -LC:/users/cazan/appdata/local/alire/cache/toolchains/gnat_native_15.2.1_346e2e00/lib/gcc/x86_64-w64-mingw32/15.2.0/adalib/
   --   -static
   --   -shared-libgcc
   --   -shared-libgcc
   --   -shared-libgcc
   --   -lgnat
   --   -lws2_32
   --   -Wl,--stack=0x2000000
--  END Object file/option list   

end ada_main;

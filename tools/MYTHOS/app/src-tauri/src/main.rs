// Prevents additional console window on Windows in release
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod commands;
mod state;

use commands::{agents, browser, exploits, filesystem, mythos, process};

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .manage(state::AppState::new())
        .invoke_handler(tauri::generate_handler![
            // Process management
            process::spawn_process,
            process::send_input,
            process::kill_process,
            process::list_processes,
            // Filesystem
            filesystem::read_directory,
            filesystem::read_file_content,
            filesystem::get_project_stats,
            filesystem::import_directory,
            filesystem::git_status,
            // MYTHOS
            mythos::run_phase,
            mythos::get_run_history,
            mythos::get_latest_score,
            mythos::list_phases,
            mythos::get_tasks,
            mythos::update_task_status,
            // Agents
            agents::list_agents,
            agents::get_agent_detail,
            agents::launch_agent,
            // Exploits
            exploits::list_exploit_blocks,
            exploits::get_block_content,
            exploits::search_blocks,
            // Browser
            browser::open_browser_tab,
            browser::open_oauth_popup,
            browser::close_browser_tab,
            browser::reload_browser_tab,
            browser::create_inline_browser,
            browser::show_browser,
            browser::hide_browser,
            browser::get_browser_url,
        ])
        .run(tauri::generate_context!())
        .expect("error running MYTHOS LAB");
}

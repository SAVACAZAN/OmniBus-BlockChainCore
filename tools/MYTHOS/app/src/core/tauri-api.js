import { invoke as tauriInvoke } from '@tauri-apps/api/core';
import { listen as tauriListen } from '@tauri-apps/api/event';

// Wrapper for invoke
export async function invoke(cmd, args = {}) {
  try {
    return await tauriInvoke(cmd, args);
  } catch (error) {
    console.error(`Tauri invoke error [${cmd}]:`, error);
    throw error;
  }
}

// Wrapper for listen
export async function listen(event, handler) {
  return await tauriListen(event, handler);
}

// Process management
export async function spawnProcess(program, args, workingDir, processId) {
  return await invoke('spawn_process', { program, args, workingDir, processId });
}

export async function sendInput(processId, input) {
  return await invoke('send_input', { processId, input });
}

export async function killProcess(processId) {
  return await invoke('kill_process', { processId });
}

export async function listProcesses() {
  return await invoke('list_processes');
}

// Filesystem
export async function readDirectory(path) {
  return await invoke('read_directory', { path });
}

export async function readFileContent(path) {
  return await invoke('read_file_content', { path });
}

// Project
export async function getProjectStats(sandboxPath) {
  return await invoke('get_project_stats', { sandboxPath });
}

export async function getRunHistory(mythosDataDir) {
  return await invoke('get_run_history', { mythosDataDir });
}

export async function getLatestScore(mythosDataDir) {
  return await invoke('get_latest_score', { mythosDataDir });
}

// Agents & Exploits
export async function listAgents(agentsDirs) {
  return await invoke('list_agents', { agentsDirs });
}

export async function listExploitBlocks(importedDir) {
  return await invoke('list_exploit_blocks', { importedDir });
}

export async function getBlockContent(importedDir, file) {
  return await invoke('get_block_content', { importedDir, file });
}
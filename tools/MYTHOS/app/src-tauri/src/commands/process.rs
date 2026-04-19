use crate::state::{AppState, ProcessHandle};
use std::process::Stdio;
use tauri::{AppHandle, Emitter, State};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

#[cfg(target_os = "windows")]
use std::os::windows::process::CommandExt;

#[tauri::command]
pub async fn spawn_process(
    app: AppHandle,
    state: State<'_, AppState>,
    program: String,
    args: Vec<String>,
    working_dir: String,
    process_id: String,
) -> Result<String, String> {
    let mut cmd = tokio::process::Command::new(&program);
    cmd.args(&args)
        .current_dir(&working_dir)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .stdin(Stdio::piped());

    // Windows: hide the console window — output goes to our app, not a new CMD window
    #[cfg(target_os = "windows")]
    cmd.creation_flags(0x08000000); // CREATE_NO_WINDOW

    let mut child = cmd.spawn()
        .map_err(|e| format!("Failed to spawn {}: {}", program, e))?;

    let pid = child.id().unwrap_or(0);

    let stdout = child.stdout.take().ok_or("Failed to capture stdout")?;
    let stderr = child.stderr.take().ok_or("Failed to capture stderr")?;
    let stdin = child.stdin.take();

    // Store in state
    {
        let mut processes = state.processes.lock().await;
        processes.insert(
            process_id.clone(),
            ProcessHandle { child, stdin },
        );
    }

    // Stream stdout
    let app_clone = app.clone();
    let id_clone = process_id.clone();
    tokio::spawn(async move {
        let reader = BufReader::new(stdout);
        let mut lines = reader.lines();
        while let Ok(Some(line)) = lines.next_line().await {
            let event_name = format!("process-output-{}", id_clone);
            let _ = app_clone.emit(&event_name, line);
        }
        let _ = app_clone.emit(&format!("process-exit-{}", id_clone), "stdout closed");
    });

    // Stream stderr
    let app_clone2 = app.clone();
    let id_clone2 = process_id.clone();
    tokio::spawn(async move {
        let reader = BufReader::new(stderr);
        let mut lines = reader.lines();
        while let Ok(Some(line)) = lines.next_line().await {
            let event_name = format!("process-output-{}", id_clone2);
            let _ = app_clone2.emit(&event_name, format!("[stderr] {}", line));
        }
    });

    Ok(format!("Process {} started (PID: {})", program, pid))
}

#[tauri::command]
pub async fn send_input(
    state: State<'_, AppState>,
    process_id: String,
    input: String,
) -> Result<(), String> {
    let mut processes = state.processes.lock().await;
    if let Some(handle) = processes.get_mut(&process_id) {
        if let Some(stdin) = handle.stdin.as_mut() {
            stdin
                .write_all(input.as_bytes())
                .await
                .map_err(|e| e.to_string())?;
            stdin.write_all(b"\n").await.map_err(|e| e.to_string())?;
            Ok(())
        } else {
            Err("Process stdin not available".to_string())
        }
    } else {
        Err(format!("Process {} not found", process_id))
    }
}

#[tauri::command]
pub async fn kill_process(
    state: State<'_, AppState>,
    process_id: String,
) -> Result<(), String> {
    let mut processes = state.processes.lock().await;
    if let Some(handle) = processes.remove(&process_id) {
        let mut child = handle.child;
        child.kill().await.map_err(|e| e.to_string())?;
        Ok(())
    } else {
        Err(format!("Process {} not found", process_id))
    }
}

#[tauri::command]
pub async fn list_processes(state: State<'_, AppState>) -> Result<Vec<String>, String> {
    let processes = state.processes.lock().await;
    Ok(processes.keys().cloned().collect())
}

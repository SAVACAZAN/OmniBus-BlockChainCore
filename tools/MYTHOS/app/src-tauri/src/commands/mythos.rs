use std::fs;

#[tauri::command]
pub fn get_run_history(mythos_data_dir: String) -> Result<Vec<serde_json::Value>, String> {
    let mut runs = Vec::new();
    let dir = fs::read_dir(&mythos_data_dir).map_err(|e| e.to_string())?;
    for entry in dir.filter_map(|e| e.ok()) {
        let name = entry.file_name().to_string_lossy().to_string();
        if name.starts_with("run_") && name.ends_with(".json") {
            let content = fs::read_to_string(entry.path()).map_err(|e| e.to_string())?;
            let data: serde_json::Value =
                serde_json::from_str(&content).map_err(|e| e.to_string())?;
            runs.push(data);
        }
    }
    runs.sort_by(|a, b| {
        a["timestamp"]
            .as_str()
            .unwrap_or("")
            .cmp(b["timestamp"].as_str().unwrap_or(""))
    });
    Ok(runs)
}

#[tauri::command]
pub fn get_latest_score(mythos_data_dir: String) -> Result<serde_json::Value, String> {
    let runs = get_run_history(mythos_data_dir)?;
    runs.last()
        .cloned()
        .ok_or_else(|| "No runs found".to_string())
}

#[tauri::command]
pub fn list_phases() -> Result<Vec<serde_json::Value>, String> {
    Ok(vec![
        serde_json::json!({"id": "crypto", "name": "CRYPTO VERIFICATION", "desc": "NIST ECDSA, Wycheproof, SHA-256, RIPEMD-160, FIPS 140-2, BIP-32/39"}),
        serde_json::json!({"id": "security", "name": "SECURITY AUDIT", "desc": "Solidity audit, Symbolic analysis, Vuln signatures, P2P attack patterns"}),
        serde_json::json!({"id": "build", "name": "BUILD & TEST", "desc": "Zig build, Test suites, Solidity compile, TypeScript check"}),
        serde_json::json!({"id": "exploits", "name": "EXPLOIT LAB", "desc": "Differential fuzzing, Crypto edge cases, DAO/Parity/Wormhole replay, 0-day"}),
        serde_json::json!({"id": "stress", "name": "STRESS / DDoS", "desc": "TX flood, P2P connection flood, Memory pressure, Gas stress test"}),
        serde_json::json!({"id": "network", "name": "NETWORK / TOR", "desc": "RPC tester, Tor connectivity, Traffic analysis, Onion privacy audit"}),
        serde_json::json!({"id": "analysis", "name": "CODE ANALYSIS", "desc": "Complexity, Dependencies, API surface, Git evolution, Quality metrics"}),
        serde_json::json!({"id": "reverse", "name": "REVERSE ENG.", "desc": "Binary hardening, ROP scan, Block malformation, ABI reconstruct"}),
    ])
}

#[tauri::command]
pub fn run_phase(phase: String) -> Result<serde_json::Value, String> {
    Ok(serde_json::json!({
        "phase": phase,
        "status": "queued",
        "message": "Use spawn_process to run the actual phase"
    }))
}

// ═══ TASK MANAGER ═══
#[tauri::command]
pub fn get_tasks(mythos_data_dir: String) -> Result<serde_json::Value, String> {
    let path = format!("{}\\tasks.json", mythos_data_dir);
    let content = fs::read_to_string(&path).map_err(|e| e.to_string())?;
    let data: serde_json::Value = serde_json::from_str(&content).map_err(|e| e.to_string())?;
    Ok(data)
}

#[tauri::command]
pub fn update_task_status(
    mythos_data_dir: String,
    task_id: String,
    status: String,
    progress: u8,
) -> Result<serde_json::Value, String> {
    let path = format!("{}\\tasks.json", mythos_data_dir);
    let content = fs::read_to_string(&path).map_err(|e| e.to_string())?;
    let mut data: serde_json::Value = serde_json::from_str(&content).map_err(|e| e.to_string())?;

    if let Some(tasks) = data["tasks"].as_array_mut() {
        for task in tasks.iter_mut() {
            if task["id"].as_str() == Some(&task_id) {
                task["status"] = serde_json::Value::String(status.clone());
                task["progress"] = serde_json::Value::Number(serde_json::Number::from(progress));
                break;
            }
        }
    }

    let new_content = serde_json::to_string_pretty(&data).map_err(|e| e.to_string())?;
    fs::write(&path, new_content).map_err(|e| e.to_string())?;
    Ok(data)
}

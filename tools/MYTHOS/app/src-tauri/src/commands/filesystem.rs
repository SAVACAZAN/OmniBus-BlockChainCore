use serde::Serialize;
use std::fs;
use std::path::Path;
use std::process::Command;

#[derive(Serialize)]
pub struct FileEntry {
    name: String,
    path: String,
    is_dir: bool,
    size: u64,
    extension: String,
    children_count: usize,
}

#[tauri::command]
pub fn read_directory(path: String) -> Result<Vec<FileEntry>, String> {
    let entries = fs::read_dir(&path).map_err(|e| e.to_string())?;
    let mut result: Vec<FileEntry> = entries
        .filter_map(|e| e.ok())
        .map(|e| {
            let meta = e.metadata().ok();
            let is_dir = meta.as_ref().map(|m| m.is_dir()).unwrap_or(false);
            let size = meta.as_ref().map(|m| m.len()).unwrap_or(0);
            let name = e.file_name().to_string_lossy().to_string();
            let ext = Path::new(&name)
                .extension()
                .unwrap_or_default()
                .to_string_lossy()
                .to_string();
            let children = if is_dir {
                fs::read_dir(e.path()).map(|r| r.count()).unwrap_or(0)
            } else {
                0
            };
            FileEntry {
                name,
                path: e.path().to_string_lossy().to_string(),
                is_dir,
                size,
                extension: ext,
                children_count: children,
            }
        })
        .collect();
    result.sort_by(|a, b| {
        b.is_dir
            .cmp(&a.is_dir)
            .then(a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    Ok(result)
}

#[tauri::command]
pub fn read_file_content(path: String) -> Result<String, String> {
    fs::read_to_string(&path).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn get_project_stats(sandbox_path: String) -> Result<serde_json::Value, String> {
    fn count_files(dir: &str, exts: &[&str]) -> usize {
        let mut count = 0;
        if let Ok(entries) = fs::read_dir(dir) {
            for entry in entries.filter_map(|e| e.ok()) {
                let path = entry.path();
                if path.is_dir() {
                    if let Some(p) = path.to_str() {
                        count += count_files(p, exts);
                    }
                } else if let Some(ext) = path.extension() {
                    let e = ext.to_string_lossy().to_lowercase();
                    if exts.contains(&e.as_str()) {
                        count += 1;
                    }
                }
            }
        }
        count
    }

    let aweb3 = format!("{}\\OmniBus - aweb3", sandbox_path);
    let bc = format!("{}\\OmniBus-BlockChainCore", sandbox_path);

    Ok(serde_json::json!({
        "aweb3": {
            "agents": count_files(&format!("{}\\.claude\\agents", aweb3), &["md"]),
            "scripts": count_files(&format!("{}\\scripts", aweb3), &["py", "js", "ts", "sol", "sh"]),
            "contracts": count_files(&format!("{}\\contracts", aweb3), &["sol"]),
        },
        "blockchaincore": {
            "agents": count_files(&format!("{}\\.claude\\agents", bc), &["md"]),
            "tools": count_files(&format!("{}\\tools", bc), &["py", "zig", "js", "sh", "rs", "go"]),
            "zig_modules": count_files(&format!("{}\\core", bc), &["zig"]),
        },
        "mythos_runs": 0,
        "last_score": 0.0
    }))
}

#[tauri::command]
pub fn import_directory(path: String, extensions: Vec<String>) -> Result<Vec<FileEntry>, String> {
    let mut result = Vec::new();
    fn scan(dir: &str, exts: &[String], out: &mut Vec<FileEntry>) -> Result<(), String> {
        for entry in fs::read_dir(dir).map_err(|e| e.to_string())?.filter_map(|e| e.ok()) {
            let path = entry.path();
            let meta = entry.metadata().map_err(|e| e.to_string())?;
            if meta.is_dir() {
                if let Some(p) = path.to_str() {
                    let name = entry.file_name().to_string_lossy().to_string();
                    if !name.starts_with('.') && !name.starts_with("node_modules") && !name.starts_with("target") {
                        scan(p, exts, out)?;
                    }
                }
            } else if let Some(ext) = path.extension() {
                let e = ext.to_string_lossy().to_lowercase();
                if exts.is_empty() || exts.contains(&e) {
                    let name = entry.file_name().to_string_lossy().to_string();
                    out.push(FileEntry {
                        name: name.clone(),
                        path: path.to_string_lossy().to_string(),
                        is_dir: false,
                        size: meta.len(),
                        extension: e,
                        children_count: 0,
                    });
                }
            }
        }
        Ok(())
    }
    scan(&path, &extensions, &mut result)?;
    result.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    Ok(result)
}

#[tauri::command]
pub fn git_status(repo_path: String) -> Result<serde_json::Value, String> {
    let path = Path::new(&repo_path);
    if !path.join(".git").exists() {
        return Err("Not a git repository".to_string());
    }

    let branch = Command::new("git")
        .args(["-C", &repo_path, "branch", "--show-current"])
        .output()
        .map_err(|e| e.to_string())?;
    let branch_str = String::from_utf8_lossy(&branch.stdout).trim().to_string();

    let log = Command::new("git")
        .args(["-C", &repo_path, "log", "-1", "--format=%H|%s|%ci"])
        .output()
        .map_err(|e| e.to_string())?;
    let log_out = String::from_utf8_lossy(&log.stdout);
    let log_parts: Vec<&str> = log_out.trim().split('|').collect();

    let status = Command::new("git")
        .args(["-C", &repo_path, "status", "--short"])
        .output()
        .map_err(|e| e.to_string())?;
    let status_lines: Vec<String> = String::from_utf8_lossy(&status.stdout)
        .lines()
        .map(|l| l.to_string())
        .filter(|l| !l.is_empty())
        .collect();

    Ok(serde_json::json!({
        "branch": branch_str,
        "last_commit_hash": log_parts.get(0).unwrap_or(&""),
        "last_commit_msg": log_parts.get(1).unwrap_or(&""),
        "last_commit_date": log_parts.get(2).unwrap_or(&""),
        "status_lines": status_lines,
        "dirty": !status_lines.is_empty(),
    }))
}

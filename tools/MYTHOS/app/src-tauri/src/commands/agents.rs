use serde::Serialize;
use std::fs;

#[derive(Serialize)]
pub struct AgentInfo {
    name: String,
    model: String,
    project: String,
    file_path: String,
    description: String,
}

fn extract_frontmatter(content: &str, key: &str) -> String {
    for line in content.lines() {
        if line.starts_with(&format!("{}:", key)) {
            return line
                .split(':')
                .skip(1)
                .collect::<Vec<_>>()
                .join(":")
                .trim()
                .trim_matches('"')
                .to_string();
        }
    }
    String::new()
}

#[tauri::command]
pub fn list_agents(agents_dirs: Vec<String>) -> Result<Vec<AgentInfo>, String> {
    let mut agents = Vec::new();
    for dir in agents_dirs {
        if let Ok(entries) = fs::read_dir(&dir) {
            for entry in entries.filter_map(|e| e.ok()) {
                if entry.path().extension().map(|e| e == "md").unwrap_or(false) {
                    let content = fs::read_to_string(entry.path()).unwrap_or_default();
                    let name = extract_frontmatter(&content, "name");
                    let model = extract_frontmatter(&content, "model");
                    let project = if dir.contains("aweb3") {
                        "aweb3"
                    } else {
                        "BlockChainCore"
                    };
                    let desc = content
                        .lines()
                        .skip(10)
                        .take(3)
                        .collect::<Vec<_>>()
                        .join(" ");
                    agents.push(AgentInfo {
                        name: if name.is_empty() {
                            entry.file_name().to_string_lossy().to_string()
                        } else {
                            name
                        },
                        model,
                        project: project.to_string(),
                        file_path: entry.path().to_string_lossy().to_string(),
                        description: desc,
                    });
                }
            }
        }
    }
    Ok(agents)
}

#[tauri::command]
pub fn get_agent_detail(file_path: String) -> Result<String, String> {
    fs::read_to_string(&file_path).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn launch_agent(name: String) -> Result<String, String> {
    Ok(format!("Agent {} launch requested (use spawn_process for real execution)", name))
}

use std::collections::HashMap;
use std::sync::Arc;
use tokio::process::{Child, ChildStdin};
use tokio::sync::Mutex;

pub struct ProcessHandle {
    pub child: Child,
    pub stdin: Option<ChildStdin>,
}

pub struct AppState {
    pub processes: Arc<Mutex<HashMap<String, ProcessHandle>>>,
}

impl AppState {
    pub fn new() -> Self {
        Self {
            processes: Arc::new(Mutex::new(HashMap::new())),
        }
    }
}

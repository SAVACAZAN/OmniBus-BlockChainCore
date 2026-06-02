//! Strategy registry RPC handlers — port of `core/rpc/strategies.zig`.
//!
//! Methods:
//!   * strategy_register — register a new operator strategy
//!   * strategy_activate — flip status to Active
//!   * strategy_get      — fetch one strategy by id
//!   * strategy_list     — list strategy ids by owner or agent_id

use crate::strategy_registry::{
    activate, get_by_id, list_by_agent, list_by_owner, register, Strategy,
};
use crate::AppState;
use serde_json::{json, Value};

use super::helpers::{param_str, param_u64};

fn strategy_to_json(s: &Strategy) -> Value {
    json!({
        "id":           s.id,
        "agent_id":     s.agent_id,
        "owner":        s.owner,
        "name":         s.name,
        "type":         s.stype.as_str(),
        "status":       s.status.as_str(),
        "params":       s.params,
        "created_at":   s.created_at,
        "activated_at": s.activated_at,
        "fill_count":   s.fill_count,
        "pnl_sat":      s.pnl_sat,
    })
}

/// `strategy_register` — register a new operator-defined strategy.
pub fn strategy_register(_app: &AppState, params: &Value) -> Result<Value, String> {
    let agent_id = param_u64(params, "agent_id").ok_or("missing agent_id")?;
    let owner = param_str(params, "owner").ok_or("missing owner")?;
    let name = param_str(params, "name").ok_or("missing name")?;
    let type_str = param_str(params, "type").unwrap_or("custom");
    let params_json = param_str(params, "params").unwrap_or("{}");

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);

    let id = register(agent_id, owner, name, type_str, params_json, now);
    if id == 0 {
        return Err("registry full".to_string());
    }
    Ok(json!({ "id": id }))
}

/// `strategy_activate` — flip a Draft strategy to Active.
pub fn strategy_activate(_app: &AppState, params: &Value) -> Result<Value, String> {
    let id = param_u64(params, "id").ok_or("missing id")?;
    if !activate(id) {
        return Err("strategy not found".to_string());
    }
    Ok(json!({ "activated": true, "id": id }))
}

/// `strategy_get` — fetch a single strategy by id.
pub fn strategy_get(_app: &AppState, params: &Value) -> Result<Value, String> {
    let id = param_u64(params, "id").ok_or("missing id")?;
    match get_by_id(id) {
        Some(s) => Ok(strategy_to_json(&s)),
        None => Err("strategy not found".to_string()),
    }
}

/// `strategy_list` — list strategy ids by owner address or agent_id.
pub fn strategy_list(_app: &AppState, params: &Value) -> Result<Value, String> {
    if let Some(owner) = param_str(params, "owner") {
        return Ok(json!({ "ids": list_by_owner(owner) }));
    }
    if let Some(agent_id) = param_u64(params, "agent_id") {
        return Ok(json!({ "ids": list_by_agent(agent_id) }));
    }
    Err("provide owner or agent_id".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::strategy_registry::clear_global_for_test;

    fn make_app() -> AppState {
        // Tests here exercise the pure registry-state behaviour via the
        // singleton; AppState is unused but required by the handler signature.
        // We never actually call the handlers without a real AppState.
        unreachable!("constructed only via app code paths")
    }

    #[test]
    fn list_by_owner_via_global() {
        clear_global_for_test();
        let _ = make_app; // suppress unused fn
        let id = register(1, "ob1qowner", "n", "grid", "{}", 0);
        assert_ne!(id, 0);
        let ids = list_by_owner("ob1qowner");
        assert_eq!(ids, vec![id]);
    }
}

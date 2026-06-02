#!/usr/bin/env bash
# 04-agents.sh — AI agents registry + decisions
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
parse_flags "$@"
SUITE_TITLE="04 Agents"
print_header "$SUITE_TITLE"

# 1) getagents (legacy name)
resp=$(rpc "getagents" "[]")
assert_ok "$resp" "getagents"

# 2) getagent {id:0}
resp=$(rpc "getagent" '[{"id":0}]')
assert_ok "$resp" "getagent id=0"

# 3) agent_list (new namespaced name)
resp=$(rpc "agent_list" "[]")
assert_ok "$resp" "agent_list"

# 4) agent_pending_decisions
resp=$(rpc "agent_pending_decisions" "[]")
assert_ok "$resp" "agent_pending_decisions"

# 5) agent_pending_decisions with limit
resp=$(rpc "agent_pending_decisions" '[{"limit":20}]')
assert_ok "$resp" "agent_pending_decisions limit=20"

finish

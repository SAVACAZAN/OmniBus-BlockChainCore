#!/usr/bin/env bash
# _common.sh — Shared helpers for OmniBus blockchain test suite
# Source this from every test script: source "$(dirname "$0")/_common.sh"

# ----- Colors -----
if [ "${NO_COLOR:-0}" = "1" ] || [ "${1:-}" = "--no-color" ]; then
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_DIM=""; C_RESET=""
else
    C_RED=$'\033[0;31m'
    C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[0;33m'
    C_BLUE=$'\033[0;34m'
    C_DIM=$'\033[2m'
    C_RESET=$'\033[0m'
fi

# ----- Mode flags (parsed from argv by individual scripts; defaults safe) -----
QUIET=${QUIET:-0}
VERBOSE=${VERBOSE:-0}

# Allow individual scripts to call parse_flags "$@" once at the top.
parse_flags() {
    for arg in "$@"; do
        case "$arg" in
            -q|--quiet)     QUIET=1 ;;
            -v|--verbose)   VERBOSE=1 ;;
            --no-color)     C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_DIM=""; C_RESET="" ;;
        esac
    done
}

# ----- Counters -----
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# ----- URL derivation -----
# CHAIN env var: mainnet (default) | testnet | regtest
# RPC_URL override env var also respected (full URL).
derive_url() {
    if [ -n "${RPC_URL:-}" ]; then
        echo "$RPC_URL"
        return 0
    fi
    local chain="${CHAIN:-mainnet}"
    case "$chain" in
        mainnet) echo "https://omnibusblockchain.cc:8443/api-mainnet" ;;
        testnet) echo "https://omnibusblockchain.cc:8443/api-testnet" ;;
        regtest) echo "https://omnibusblockchain.cc:8443/api-regtest" ;;
        local-mainnet)   echo "http://127.0.0.1:8332" ;;
        local-testnet)   echo "http://127.0.0.1:18332" ;;
        local-regtest)   echo "http://127.0.0.1:28332" ;;
        *) echo "https://omnibusblockchain.cc:8443/api-mainnet" ;;
    esac
}

RPC_BEARER="${OMNIBUS_RPC_TOKEN:-}"

# ----- Output helpers -----
print_header() {
    [ "$QUIET" = "1" ] && return 0
    local title="$1"
    echo
    echo "${C_BLUE}=== $title ===${C_RESET}"
    echo "${C_DIM}URL: $(derive_url)   CHAIN=${CHAIN:-mainnet}${C_RESET}"
}

print_pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    [ "$QUIET" = "1" ] && return 0
    echo "  ${C_GREEN}PASS${C_RESET} $1"
}

print_fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "  ${C_RED}FAIL${C_RESET} $1"
    if [ -n "${2:-}" ] && [ "$QUIET" != "1" ]; then
        echo "${C_DIM}        $2${C_RESET}"
    fi
}

print_skip() {
    SKIP_COUNT=$((SKIP_COUNT + 1))
    [ "$QUIET" = "1" ] && return 0
    echo "  ${C_YELLOW}SKIP${C_RESET} $1${2:+ ${C_DIM}($2)${C_RESET}}"
}

print_info() {
    [ "$QUIET" = "1" ] && return 0
    echo "  ${C_DIM}info $1${C_RESET}"
}

print_summary() {
    local title="${1:-Suite}"
    echo
    echo "${C_BLUE}--- $title summary ---${C_RESET}"
    echo "  ${C_GREEN}pass: $PASS_COUNT${C_RESET}   ${C_RED}fail: $FAIL_COUNT${C_RESET}   ${C_YELLOW}skip: $SKIP_COUNT${C_RESET}"
}

# ----- jq detection (graceful fallback) -----
HAS_JQ=0
if command -v jq >/dev/null 2>&1; then
    HAS_JQ=1
fi

# ----- Core RPC -----
# rpc method [params_json]   --> echoes raw JSON response on stdout
rpc() {
    local method="$1"
    local params="${2:-[]}"
    local url
    url="$(derive_url)"
    local payload
    payload=$(printf '{"jsonrpc":"2.0","id":1,"method":"%s","params":%s}' "$method" "$params")

    if [ "$VERBOSE" = "1" ]; then
        echo "${C_DIM}>> POST $url   $payload${C_RESET}" >&2
    fi

    local hdr_auth=()
    if [ -n "$RPC_BEARER" ]; then
        hdr_auth=(-H "Authorization: Bearer $RPC_BEARER")
    fi

    # 15s timeout, fail-soft (don't kill script on transport error)
    local resp
    resp=$(curl -sS --max-time 15 -X POST \
        -H "Content-Type: application/json" \
        "${hdr_auth[@]}" \
        --data-raw "$payload" \
        "$url" 2>/dev/null) || resp='{"error":{"message":"transport_error","code":-32000}}'

    if [ -z "$resp" ]; then
        resp='{"error":{"message":"empty_response","code":-32001}}'
    fi

    if [ "$VERBOSE" = "1" ]; then
        echo "${C_DIM}<< $resp${C_RESET}" >&2
    fi
    echo "$resp"
}

# ----- JSON helpers (jq if available, grep/sed fallback) -----
# Extract result.X.Y or whole result.
json_get() {
    local json="$1"
    local path="$2"   # e.g. ".result.cups.love" or ".result"
    if [ "$HAS_JQ" = "1" ]; then
        echo "$json" | jq -r "$path // empty" 2>/dev/null
    else
        # very basic fallback: only handles .result, .error, .error.message, top keys
        case "$path" in
            ".result")
                echo "$json" | sed -n 's/.*"result":\(.*\)\(,"id":\|}$\).*/\1/p' | head -c 4000
                ;;
            ".error.message")
                echo "$json" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p'
                ;;
            ".error.code")
                echo "$json" | sed -n 's/.*"code":\(-\?[0-9]*\).*/\1/p'
                ;;
            *)
                # try to grep a top-level key from result
                local key
                key=$(echo "$path" | sed 's/^\.result\.//; s/\..*$//')
                echo "$json" | sed -n "s/.*\"$key\":\([^,}]*\).*/\1/p" | head -1 | sed 's/^"//; s/"$//'
                ;;
        esac
    fi
}

# ----- Assertions -----
# Returns 0 on pass, 1 on fail. Prints PASS/FAIL line.
assert_ok() {
    local json="$1"
    local label="$2"
    local err
    err=$(json_get "$json" ".error.message")
    if [ -n "$err" ] && [ "$err" != "null" ]; then
        # Detect "method not found" -> caller can choose SKIP
        if echo "$err" | grep -qiE "method not found|unknown method|not implemented|method.*found"; then
            print_skip "$label" "method not found"
            return 2
        fi
        print_fail "$label" "rpc error: $err"
        return 1
    fi
    # also check if "result" key is present
    if ! echo "$json" | grep -q '"result"'; then
        print_fail "$label" "no result field"
        return 1
    fi
    print_pass "$label"
    return 0
}

assert_eq() {
    local actual="$1"
    local expected="$2"
    local label="$3"
    if [ "$actual" = "$expected" ]; then
        print_pass "$label"
        return 0
    fi
    print_fail "$label" "expected='$expected' actual='$actual'"
    return 1
}

# Check that the JSON-RPC result has a given field somewhere in the result body.
assert_has_field() {
    local json="$1"
    local field="$2"
    local label="$3"
    if echo "$json" | grep -q "\"$field\""; then
        print_pass "$label"
        return 0
    fi
    print_fail "$label" "missing field '$field'"
    return 1
}

# Convenience: run an rpc, assert ok, and pass the JSON to a custom validator (optional).
# Usage: rpc_check method params label [validator-fn-name]
rpc_check() {
    local method="$1"
    local params="$2"
    local label="$3"
    local validator="${4:-}"
    local resp
    resp=$(rpc "$method" "$params")
    assert_ok "$resp" "$label"
    local rc=$?
    if [ "$rc" = "0" ] && [ -n "$validator" ]; then
        "$validator" "$resp"
    fi
    # Make response available to caller:
    LAST_RESPONSE="$resp"
    return $rc
}

# Final exit handler: scripts call `finish` at end.
finish() {
    print_summary "${SUITE_TITLE:-Suite}"
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
    exit 0
}

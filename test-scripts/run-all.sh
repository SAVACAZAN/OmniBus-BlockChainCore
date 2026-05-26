#!/usr/bin/env bash
# run-all.sh — Run every numbered test script in order, aggregate results
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Don't source _common.sh: child scripts source it. We just orchestrate.

# ---- argv parsing ----
CHAIN_ARG=""
PASS_FLAGS=()
for ((i=1; i<=$#; i++)); do
    arg="${!i}"
    case "$arg" in
        --chain)
            j=$((i+1))
            CHAIN_ARG="${!j:-}"
            i=$j
            ;;
        --chain=*)
            CHAIN_ARG="${arg#--chain=}"
            ;;
        -q|--quiet|-v|--verbose|--no-color)
            PASS_FLAGS+=("$arg")
            ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--chain mainnet|testnet|regtest|local-mainnet|local-testnet|local-regtest] [-q|-v] [--no-color]

Env vars:
  CHAIN              same effect as --chain
  RPC_URL            override URL entirely
  OMNIBUS_RPC_TOKEN  Bearer token (set in nginx-proxied seed)
  NO_COLOR=1         disable color
EOF
            exit 0
            ;;
    esac
done

if [ -n "$CHAIN_ARG" ]; then
    export CHAIN="$CHAIN_ARG"
fi

# ---- colors for the orchestrator's own output ----
if [ "${NO_COLOR:-0}" = "1" ]; then
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_DIM=""; C_RESET=""
else
    C_RED=$'\033[0;31m'
    C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[0;33m'
    C_BLUE=$'\033[0;34m'
    C_DIM=$'\033[2m'
    C_RESET=$'\033[0m'
fi

echo "${C_BLUE}=========================================================${C_RESET}"
echo "${C_BLUE} OmniBus Blockchain Test Suite${C_RESET}"
echo "${C_BLUE} CHAIN=${CHAIN:-mainnet}${C_RESET}"
echo "${C_BLUE}=========================================================${C_RESET}"

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
SUITE_FAIL=0
SUITES_RUN=0

# Find numbered test scripts (01- ... 99-) — both .sh and .mjs.
SCRIPTS=$(ls "$SCRIPT_DIR"/[0-9][0-9]-*.sh "$SCRIPT_DIR"/[0-9][0-9]-*.mjs 2>/dev/null | sort)

# Section header is printed when we cross into the 30+ range (Integration + E2E).
PRINTED_E2E_HEADER=0

for script in $SCRIPTS; do
    SUITES_RUN=$((SUITES_RUN + 1))
    name=$(basename "$script")

    # Print Integration + E2E banner the first time we see a 30+ script.
    case "$name" in
        3[0-9]-*|4[0-9]-*)
            if [ "$PRINTED_E2E_HEADER" = "0" ]; then
                echo
                echo "${C_BLUE}=========================================================${C_RESET}"
                echo "${C_BLUE} Integration + E2E${C_RESET}"
                echo "${C_BLUE}=========================================================${C_RESET}"
                PRINTED_E2E_HEADER=1
            fi
            ;;
    esac

    # Run script, capture output and exit status
    case "$script" in
        *.mjs)
            # Pass --chain through to Node scripts; bash flags are not recognised by .mjs.
            mjs_args=()
            if [ -n "${CHAIN:-}" ]; then mjs_args+=(--chain "$CHAIN"); fi
            # Multi-wallet flow scripts (23-30): write-state-changing + the
            # full-stress orchestrator can take 30 min, so default to dry-run
            # in run-all unless RUN_MULTIWALLET_WRITE=1 is exported.
            case "$name" in
                2[3-9]-multiwallet-*.mjs|30-multiwallet-*.mjs)
                    if [ "${RUN_MULTIWALLET_WRITE:-0}" != "1" ]; then
                        mjs_args+=(--dry-run)
                    fi
                    if [ "$name" = "30-multiwallet-full-stress.mjs" ] && \
                       [ "${RUN_MULTIWALLET_FULL:-0}" != "1" ]; then
                        # Skip the 30-min orchestrator unless explicitly requested.
                        echo "${C_YELLOW}    skipping ${name} (set RUN_MULTIWALLET_FULL=1 to run)${C_RESET}"
                        SUITES_RUN=$((SUITES_RUN - 1))
                        continue
                    fi
                    ;;
            esac
            out=$(node "$script" "${mjs_args[@]}" 2>&1)
            ;;
        *)
            out=$(bash "$script" "${PASS_FLAGS[@]}" 2>&1)
            ;;
    esac
    rc=$?
    echo "$out"

    # Parse counts from the suite-summary line:
    #   pass: N   fail: M   skip: K
    summary_line=$(echo "$out" | grep -E "pass:[[:space:]]*[0-9]+.*fail:[[:space:]]*[0-9]+.*skip:[[:space:]]*[0-9]+" | tail -1)
    if [ -n "$summary_line" ]; then
        # Strip ANSI escape codes for safe parsing.
        clean=$(echo "$summary_line" | sed 's/\x1b\[[0-9;]*m//g')
        p=$(echo "$clean" | sed -n 's/.*pass:[[:space:]]*\([0-9]\+\).*/\1/p')
        f=$(echo "$clean" | sed -n 's/.*fail:[[:space:]]*\([0-9]\+\).*/\1/p')
        s=$(echo "$clean" | sed -n 's/.*skip:[[:space:]]*\([0-9]\+\).*/\1/p')
        TOTAL_PASS=$((TOTAL_PASS + ${p:-0}))
        TOTAL_FAIL=$((TOTAL_FAIL + ${f:-0}))
        TOTAL_SKIP=$((TOTAL_SKIP + ${s:-0}))
    fi

    if [ "$rc" != "0" ]; then
        SUITE_FAIL=$((SUITE_FAIL + 1))
        echo "${C_RED}    ! suite '$name' exited with status $rc${C_RESET}"
    fi
done

echo
echo "${C_BLUE}=========================================================${C_RESET}"
echo "${C_BLUE} Aggregate results — ${SUITES_RUN} suite(s)${C_RESET}"
echo "  ${C_GREEN}pass: $TOTAL_PASS${C_RESET}"
echo "  ${C_RED}fail: $TOTAL_FAIL${C_RESET}"
echo "  ${C_YELLOW}skip: $TOTAL_SKIP${C_RESET}"
echo "  ${C_DIM}suites failed (non-zero exit): $SUITE_FAIL${C_RESET}"
echo "${C_BLUE}=========================================================${C_RESET}"

if [ "$TOTAL_FAIL" -gt 0 ] || [ "$SUITE_FAIL" -gt 0 ]; then
    exit 1
fi
exit 0

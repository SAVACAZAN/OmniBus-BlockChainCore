# bash completion for omnibus-cli
# Install: source this file from ~/.bashrc, or copy to
#   /etc/bash_completion.d/omnibus-cli      (system)
#   ~/.local/share/bash-completion/completions/omnibus-cli   (user)
#
# Reads optional ~/.omnibus/known_addresses (one bech32 per line) for
# address argument completion.

_omnibus_cli() {
    local cur prev words cword
    _init_completion -s 2>/dev/null || {
        # Fallback if bash-completion package missing.
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
        words=("${COMP_WORDS[@]}")
        cword=$COMP_CWORD
    }

    local subcommands="balance stake reputation daily validators stakers health history verify help"
    local flags="--rpc --chain --remote --token --json --no-color --help -h"
    local chains="mainnet testnet regtest"
    local filters="all stake sent received mined"
    local tlds="omnibus arbitraje bank ai dao"

    # Pair_id values (DEX_GRID_SPEC.md): 0/2/3/5/6 active.
    local pair_ids="0 2 3 5 6"

    # ─── Flag values ─────────────────────────────────────────────────────────
    case "$prev" in
        --chain)
            COMPREPLY=( $(compgen -W "$chains" -- "$cur") )
            return 0
            ;;
        --rpc)
            COMPREPLY=( $(compgen -W "http://127.0.0.1:8332 http://127.0.0.1:18332 http://127.0.0.1:28332" -- "$cur") )
            return 0
            ;;
        --token)
            # Don't suggest tokens — security.
            return 0
            ;;
    esac

    # ─── Find subcommand position (first non-flag/non-flag-value word) ───────
    local cmd="" i=1
    while [ $i -lt $cword ]; do
        local w="${words[i]}"
        case "$w" in
            --rpc|--chain|--token) i=$((i+2)); continue ;;
            --remote|--json|--no-color|--help|-h) i=$((i+1)); continue ;;
            -*) i=$((i+1)); continue ;;
        esac
        cmd="$w"
        break
    done

    # ─── No subcommand yet → suggest subcommands + flags ─────────────────────
    if [ -z "$cmd" ]; then
        if [[ "$cur" == -* ]]; then
            COMPREPLY=( $(compgen -W "$flags" -- "$cur") )
        else
            COMPREPLY=( $(compgen -W "$subcommands $flags" -- "$cur") )
        fi
        return 0
    fi

    # ─── Subcommand-specific argument completion ─────────────────────────────
    # Position of $cur relative to the subcommand:
    local arg_pos=$((cword - i - 1))

    case "$cmd" in
        balance|stake|reputation|verify)
            if [ $arg_pos -eq 0 ]; then
                _omnibus_cli_addresses "$cur"
            fi
            ;;
        daily)
            if [ $arg_pos -eq 0 ]; then
                _omnibus_cli_addresses "$cur"
            elif [ $arg_pos -eq 1 ]; then
                COMPREPLY=( $(compgen -W "1 7 14 30 60 90" -- "$cur") )
            fi
            ;;
        history)
            if [ $arg_pos -eq 0 ]; then
                _omnibus_cli_addresses "$cur"
            elif [ $arg_pos -eq 1 ]; then
                COMPREPLY=( $(compgen -W "$filters" -- "$cur") )
            fi
            ;;
        stakers)
            if [ $arg_pos -eq 0 ]; then
                COMPREPLY=( $(compgen -W "5 10 20 50 100" -- "$cur") )
            fi
            ;;
        validators|health|help)
            # No positional args.
            COMPREPLY=( $(compgen -W "$flags" -- "$cur") )
            ;;
    esac

    # Always offer flags after the subcommand.
    if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "$flags" -- "$cur") )
    fi
}

# Helper: complete addresses from ~/.omnibus/known_addresses
_omnibus_cli_addresses() {
    local cur="$1"
    local addrs=""
    if [ -r "$HOME/.omnibus/known_addresses" ]; then
        addrs=$(grep -v '^#' "$HOME/.omnibus/known_addresses" | grep -v '^$')
    fi
    # Always include the canonical mining wallet #0 + faucet for convenience.
    addrs="$addrs ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0"
    COMPREPLY=( $(compgen -W "$addrs" -- "$cur") )
}

complete -F _omnibus_cli omnibus-cli

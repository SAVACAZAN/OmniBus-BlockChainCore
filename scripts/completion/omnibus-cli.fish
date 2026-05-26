# fish completion for omnibus-cli
# Install: copy to ~/.config/fish/completions/omnibus-cli.fish

# ─── Helper: detect whether a subcommand has been seen yet ──────────────────
function __omnibus_cli_no_subcommand
    set -l cmd (commandline -opc)
    set -l subs balance stake reputation daily validators stakers health history verify help
    set -l skip_next 0
    for token in $cmd[2..-1]
        if test $skip_next -eq 1
            set skip_next 0
            continue
        end
        switch $token
            case --rpc --chain --token
                set skip_next 1
            case --remote --json --no-color --help -h
                # boolean flags, no value
            case '-*'
                # unknown flag, ignore
            case '*'
                # if it matches a subcommand we already have one
                if contains -- $token $subs
                    return 1
                end
        end
    end
    return 0
end

function __omnibus_cli_using_subcommand
    set -l target $argv[1]
    set -l cmd (commandline -opc)
    set -l skip_next 0
    for token in $cmd[2..-1]
        if test $skip_next -eq 1
            set skip_next 0
            continue
        end
        switch $token
            case --rpc --chain --token
                set skip_next 1
            case '-*'
                # flags don't count
            case '*'
                if test "$token" = "$target"
                    return 0
                else
                    return 1
                end
        end
    end
    return 1
end

function __omnibus_cli_addresses
    if test -r ~/.omnibus/known_addresses
        grep -v '^#' ~/.omnibus/known_addresses | grep -v '^$'
    end
    echo 'ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0'
end

# ─── Global flags (always offered) ──────────────────────────────────────────
complete -c omnibus-cli -l rpc       -d 'Override RPC URL' -x \
    -a 'http://127.0.0.1:8332 http://127.0.0.1:18332 http://127.0.0.1:28332'
complete -c omnibus-cli -l chain     -d 'Select chain' -x \
    -a 'mainnet testnet regtest'
complete -c omnibus-cli -l remote    -d 'Use omnibusblockchain.cc HTTPS'
complete -c omnibus-cli -l token     -d 'RPC bearer token' -x
complete -c omnibus-cli -l json      -d 'Raw JSON output'
complete -c omnibus-cli -l no-color  -d 'Disable ANSI colors'
complete -c omnibus-cli -s h -l help -d 'Show help'

# ─── Subcommands (only when none chosen yet) ────────────────────────────────
complete -c omnibus-cli -n __omnibus_cli_no_subcommand -f \
    -a balance    -d 'Full balance breakdown'
complete -c omnibus-cli -n __omnibus_cli_no_subcommand -f \
    -a stake      -d 'Current stake + activity log'
complete -c omnibus-cli -n __omnibus_cli_no_subcommand -f \
    -a reputation -d 'Reputation cups + tier'
complete -c omnibus-cli -n __omnibus_cli_no_subcommand -f \
    -a daily      -d 'Per-day TX breakdown'
complete -c omnibus-cli -n __omnibus_cli_no_subcommand -f \
    -a validators -d 'List all validators'
complete -c omnibus-cli -n __omnibus_cli_no_subcommand -f \
    -a stakers    -d 'Top stakers'
complete -c omnibus-cli -n __omnibus_cli_no_subcommand -f \
    -a health     -d 'Chain stats'
complete -c omnibus-cli -n __omnibus_cli_no_subcommand -f \
    -a history    -d 'TX history with filter'
complete -c omnibus-cli -n __omnibus_cli_no_subcommand -f \
    -a verify     -d 'Sanity check stake vs sum(TXs)'
complete -c omnibus-cli -n __omnibus_cli_no_subcommand -f \
    -a help       -d 'Show help'

# ─── Address argument for balance/stake/reputation/verify/daily/history ─────
for sub in balance stake reputation verify daily history
    complete -c omnibus-cli -n "__omnibus_cli_using_subcommand $sub" -f \
        -a '(__omnibus_cli_addresses)'
end

# ─── history filter (second positional) ─────────────────────────────────────
complete -c omnibus-cli -n '__omnibus_cli_using_subcommand history' -f \
    -a 'all stake sent received mined' \
    -d 'TX kind filter'

# ─── stakers/daily numeric arg ──────────────────────────────────────────────
complete -c omnibus-cli -n '__omnibus_cli_using_subcommand stakers' -f \
    -a '5 10 20 50 100' -d 'limit'
complete -c omnibus-cli -n '__omnibus_cli_using_subcommand daily' -f \
    -a '1 7 14 30 60 90' -d 'days'

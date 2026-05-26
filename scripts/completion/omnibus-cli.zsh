#compdef omnibus-cli
# zsh completion for omnibus-cli
# Install: place in a directory on $fpath (e.g. ~/.zsh/completions) and run
#   autoload -U compinit && compinit
# Or: copy to /usr/share/zsh/site-functions/_omnibus-cli

_omnibus_cli() {
    local context state state_descr line
    typeset -A opt_args

    local -a global_flags
    global_flags=(
        '--rpc[Override RPC URL]:url:->rpc_url'
        '--chain[Select chain]:chain:(mainnet testnet regtest)'
        '--remote[Use omnibusblockchain.cc HTTPS endpoint]'
        '--token[RPC bearer token]:token:'
        '--json[Raw JSON output]'
        '--no-color[Disable ANSI colors]'
        '(-h --help)'{-h,--help}'[Show help]'
    )

    local -a subcommands
    subcommands=(
        'balance:Full balance breakdown (wallet/stake/avail/rep)'
        'stake:Current stake + activity log'
        'reputation:Reputation cups + tier'
        'daily:Per-day TX breakdown'
        'validators:List all validators'
        'stakers:Top stakers'
        'health:Chain stats (height, mempool, peers)'
        'history:TX history with optional filter'
        'verify:Sanity check chain stake vs sum(STAKE TXs)'
        'help:Show help'
    )

    _arguments -C \
        $global_flags \
        '1: :->subcommand' \
        '*:: :->args'

    case $state in
        rpc_url)
            _values 'rpc url' \
                'http\://127.0.0.1\:8332[mainnet local]' \
                'http\://127.0.0.1\:18332[testnet local]' \
                'http\://127.0.0.1\:28332[regtest local]'
            ;;
        subcommand)
            _describe -t commands 'omnibus-cli subcommand' subcommands
            ;;
        args)
            case $line[1] in
                balance|stake|reputation|verify)
                    _omnibus_cli_addresses
                    ;;
                daily)
                    if (( CURRENT == 2 )); then
                        _omnibus_cli_addresses
                    elif (( CURRENT == 3 )); then
                        _values 'days' '1' '7' '14' '30' '60' '90'
                    fi
                    ;;
                history)
                    if (( CURRENT == 2 )); then
                        _omnibus_cli_addresses
                    elif (( CURRENT == 3 )); then
                        _values 'filter' \
                            'all[All transactions]' \
                            'stake[stake/unstake only]' \
                            'sent[Outgoing only]' \
                            'received[Incoming only]' \
                            'mined[Mining/coinbase rewards]'
                    fi
                    ;;
                stakers)
                    if (( CURRENT == 2 )); then
                        _values 'limit' '5' '10' '20' '50' '100'
                    fi
                    ;;
                validators|health|help)
                    _arguments $global_flags
                    ;;
            esac
            ;;
    esac
}

# Helper: addresses from ~/.omnibus/known_addresses + canonical wallet #0
_omnibus_cli_addresses() {
    local -a addrs
    if [[ -r "$HOME/.omnibus/known_addresses" ]]; then
        addrs=( ${(f)"$(grep -v '^#' $HOME/.omnibus/known_addresses | grep -v '^$')"} )
    fi
    addrs+=( 'ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0' )
    _describe -t addresses 'OmniBus address' addrs
}

# zsh ≥ 5: register
if [[ "$funcstack[1]" == _omnibus_cli ]]; then
    _omnibus_cli "$@"
else
    compdef _omnibus_cli omnibus-cli
fi

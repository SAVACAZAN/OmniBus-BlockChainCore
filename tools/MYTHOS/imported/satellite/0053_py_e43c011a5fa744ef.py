# ethereum_pending_tx_sniffer.py
# Sniff pending tranzacții din mempool
from web3 import Web3
import time
import json

class PendingTxSniffer:
    def __init__(self, w3: Web3):
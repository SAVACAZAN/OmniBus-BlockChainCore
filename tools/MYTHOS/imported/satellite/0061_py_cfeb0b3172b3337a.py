# atomic_arbitrage.py
# Arbitraj atomic între multiple DEX-uri
from web3 import Web3

class AtomicArbitrage:
    def __init__(self, w3: Web3, routers: list):
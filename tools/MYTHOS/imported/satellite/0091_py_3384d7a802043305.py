# aave_exploit.py
# Aave exploit - flashloan + reentrancy
from web3 import Web3

class AaveExploit:
    def __init__(self, w3: Web3, aave_pool: str):
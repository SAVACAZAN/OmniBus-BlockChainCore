# ethereum_mev_backrun.py
# MEV backrunning bot
from web3 import Web3
from web3.middleware import geth_poa_middleware
import time

class MEVBackrunBot:
    def __init__(self, w3: Web3, private_key: str):
# mev_sandwich_detector.py
# Detectează atacuri sandwich în mempool
from web3 import Web3

class SandwichDetector:
    def __init__(self, w3: Web3, uniswap_router: str):
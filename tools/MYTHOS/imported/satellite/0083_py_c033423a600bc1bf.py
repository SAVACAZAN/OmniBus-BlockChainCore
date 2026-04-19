# mev_block_builder.py
# Construiește bloc MEV optim
from web3 import Web3
import heapq

class MEVBlockBuilder:
    def __init__(self, w3: Web3):
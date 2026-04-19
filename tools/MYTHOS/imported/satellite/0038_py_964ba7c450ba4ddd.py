# ethereum_liveness_attack.py
# Liveness denial - oprește finalizarea blocului
from web3 import Web3
import time

def liveness_attack(w3, target_validators):
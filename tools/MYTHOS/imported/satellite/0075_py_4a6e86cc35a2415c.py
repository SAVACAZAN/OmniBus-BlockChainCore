# bitcoin_ibd_attack.py
# Initial Block Download (IBD) attack - forțează nodul să descarce blocuri false
from bitcoin.rpc import RawProxy
import time

class IBDAttack:
    def __init__(self, rpc: RawProxy):
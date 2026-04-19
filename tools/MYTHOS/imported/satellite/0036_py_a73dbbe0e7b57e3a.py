# bitcoin_orphan_block_inject.py
# Injectează bloc orfan în rețea
from bitcoin.rpc import RawProxy
from bitcoin.core import CBlock, COutPoint, CMutableTransaction, CTxIn, CTxOut
from bitcoin.core.script import CScript, OP_TRUE
import time

def create_orphan_block(prev_hash, height):
# bitcoin_sigops_limit_bypass.py
# Bypass limita de sigops (8000 per bloc)
from bitcoin.core import CMutableTransaction, CScript
from bitcoin.core.script import OP_CHECKSIG

def create_sigops_tx(sigops_count):
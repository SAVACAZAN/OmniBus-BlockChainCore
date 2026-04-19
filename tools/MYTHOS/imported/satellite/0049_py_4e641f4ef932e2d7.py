# bitcoin_cpfp_exploit.py
# CPFP (Child-Pays-For-Parent) abuse
from bitcoin.rpc import RawProxy
from bitcoin.core import CMutableTransaction, COutPoint, CTxIn, CTxOut
from bitcoin.core.script import CScript, OP_TRUE

def cpfp_exploit(rpc, parent_txid, fee_multiplier=100):
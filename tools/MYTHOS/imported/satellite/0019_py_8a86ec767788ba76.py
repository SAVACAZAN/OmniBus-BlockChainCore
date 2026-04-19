# bitcoin_rawtx_malleate.py
# Malleability: modifică semnătura fără a invalida tx
from bitcoin.core import CTransaction, CMutableTransaction

def malleate_tx(rawtx_hex):
    tx = CTransaction.deserialize(bytes.fromhex(rawtx_hex))
    mutable = CMutableTransaction.from_tx(tx)
    # Adaugă dummy byte în scriptSig
# bitcoin_witness_malleability.py
# Witness malleability (SegWit)
from bitcoin.core import CMutableTransaction, CTxWitness

def malleate_witness(original_tx):
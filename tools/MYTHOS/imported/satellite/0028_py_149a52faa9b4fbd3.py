# bitcoin_spv_fraud_proof.py
# Simulează SPV fraud proof (Bitcoin Core < 0.13)
from bitcoin.core import *
from bitcoin.core.script import *
import hashlib

def create_fraud_proof(real_block_header, fake_tx):
# bitcoin_mempool_flood.py
# Flood mempool cu tranzacții cu fee 1 sat/byte
from bitcoin.core import *
from bitcoin.wallet import CBitcoinSecret
import random

def flood_mempool(rpc_conn, num_tx=10000):
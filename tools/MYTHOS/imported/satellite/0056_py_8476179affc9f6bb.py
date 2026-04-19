# bitcoin_coinbase_maturity.py
# Coinbase maturity bypass (blocuri pre-mature)
from bitcoin.rpc import RawProxy

def coinbase_maturity_exploit(rpc, coinbase_txid, blocks_waited=0):
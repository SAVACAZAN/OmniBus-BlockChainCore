# mev_flashbots_bundle.py
# Creează și trimite bundle Flashbots
from web3 import Web3
import requests

class FlashbotsBundle:
    def __init__(self, w3: Web3, flashbots_endpoint: str = "https://relay.flashbots.net"):
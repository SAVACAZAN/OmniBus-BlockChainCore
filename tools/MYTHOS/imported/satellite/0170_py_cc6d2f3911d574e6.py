# regulatory_api.py
# API pentru reglementatori (FATF, FIU, Europol)
from flask import Flask, request, jsonify

app = Flask(__name__)

class RegulatoryAPI:
    def __init__(self):
# regulatory_report.py
# Generează rapoarte pentru reglementatori (FATF, FIU)
import json
from datetime import datetime

class RegulatoryReport:
    def __init__(self, entity_name: str):
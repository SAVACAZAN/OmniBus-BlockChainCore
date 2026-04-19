# forensic_audit_log.py
# Audit log pentru investigații forensice
import json
from datetime import datetime

class ForensicAuditLog:
    def __init__(self, log_file: str = "audit_log.json"):
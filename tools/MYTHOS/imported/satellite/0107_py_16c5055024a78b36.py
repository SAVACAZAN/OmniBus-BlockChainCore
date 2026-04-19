# eclipse_attack.py
# Eclipse attack - izolează un nod de restul rețelei
import socket
import random

class EclipseAttack:
    def __init__(self, target_ip: str, target_port: int):
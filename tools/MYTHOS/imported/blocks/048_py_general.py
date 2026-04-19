# orderly_attack.py
# Atac pe Orderly (perp DEX)
class OrderlyAttack:
    def __init__(self, orderly_contract: str):
        self.orderly = orderly_contract
        
    def exploit_orderly_matching(self, fake_orders: int):
        """
        Exploatează matching-ul în Orderly
        """
        print(f"[!] Orderly: order matching exploit")
        
        # Orderly are order book pentru perp-uri
        # Atac: injectează ordine false pentru a manipula prețul
        
        fake_orders_count = fake_orders
        market_manipulated = fake_orders_count > 100
        
        return {
            'attack': 'orderly_matching',
            'contract': self.orderly,
            'fake_orders': fake_orders_count,
            'market_manipulated': market_manipulated
        }
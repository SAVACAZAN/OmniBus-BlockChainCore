# gains_v2.py
# Atac pe Gains Network V2
class GainsV2:
    def __init__(self, gains_contract: str):
        self.gains = gains_contract
        
    def manipulate_gains_leverage(self, fake_leverage: float):
        """
        Manipulează leverage-ul în Gains V2
        """
        print(f"[!] Gains V2: leverage manipulation")
        
        # Gains V2 are leverage până la 100x
        # Atac: raportează leverage fals
        
        normal_leverage = 50
        fake_leverage_value = fake_leverage
        
        return {
            'attack': 'gains_leverage',
            'contract': self.gains,
            'normal_leverage': normal_leverage,
            'fake_leverage': fake_leverage_value
        }
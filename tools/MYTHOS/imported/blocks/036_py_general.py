# spark_attack.py
# Atac pe Spark (lending)
class SparkAttack:
    def __init__(self, spark_contract: str):
        self.spark = spark_contract
        
    def manipulate_spark_rewards(self, fake_deposit: int):
        """
        Manipulează recompensele Spark
        """
        print(f"[!] Spark: rewards manipulation")
        
        # Spark oferă recompense pentru depozite
        # Atac: depozit fals pentru a colecta recompense
        
        fake_deposit_amount = fake_deposit
        rewards_claimed = fake_deposit_amount * 0.03  # 3% rewards
        
        return {
            'attack': 'spark_rewards',
            'contract': self.spark,
            'fake_deposit': fake_deposit_amount,
            'rewards_claimed': rewards_claimed
        }
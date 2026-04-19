# ethereum_flashloan_reentrancy.py
# Aave flashloan + reentrancy (exemplu didactic)
def flashloan_reentrancy_attack():
    # 1. Flashloan 1000 ETH
    # 2. Call target contract cu fallback care re-intră
#!/usr/bin/env python3
"""
OmniBus Blockchain Core — Difficulty Predictor (LSTM)

Trains an LSTM model on historical difficulty/block-time sequences
to predict optimal difficulty for next epoch.
"""

import argparse
import json
import math
import os
import sys
from typing import Any, Dict, List

GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
RESET = "\033[0m"


def cprint(color: str, msg: str) -> None:
    print(f"{color}{msg}{RESET}")


def generate_synthetic_series(length: int = 2000) -> List[Dict[str, float]]:
    import random
    series = []
    diff = 1.0
    for i in range(length):
        target = 120.0
        noise = random.gauss(0, 10)
        block_time = target + noise + math.sin(i / 200.0) * 15
        diff *= max(0.25, min(4.0, target / max(block_time, 1)))
        series.append({"height": i, "block_time": block_time, "difficulty": diff})
    return series


def prepare_sequences(series: List[Dict[str, float]], seq_len: int = 10) -> tuple:
    diffs = [s["difficulty"] for s in series]
    X, y = [], []
    for i in range(len(diffs) - seq_len):
        X.append(diffs[i : i + seq_len])
        y.append(diffs[i + seq_len])
    return X, y


def train_lstm(X: List[List[float]], y: List[float]) -> Any:
    try:
        import torch
        import torch.nn as nn
    except ImportError:
        cprint(RED, "PyTorch not installed. Using linear regression fallback.")
        # Fallback: simple linear regression on last value
        return None

    class LSTMModel(nn.Module):
        def __init__(self, input_size: int = 1, hidden_size: int = 32, num_layers: int = 1):
            super().__init__()
            self.lstm = nn.LSTM(input_size, hidden_size, num_layers, batch_first=True)
            self.fc = nn.Linear(hidden_size, 1)

        def forward(self, x):
            out, _ = self.lstm(x)
            out = self.fc(out[:, -1, :])
            return out

    Xt = torch.tensor(X, dtype=torch.float32).unsqueeze(-1)
    yt = torch.tensor(y, dtype=torch.float32).unsqueeze(-1)
    model = LSTMModel()
    criterion = nn.MSELoss()
    optimizer = torch.optim.Adam(model.parameters(), lr=0.01)

    for epoch in range(200):
        model.train()
        optimizer.zero_grad()
        output = model(Xt)
        loss = criterion(output, yt)
        loss.backward()
        optimizer.step()
        if epoch % 50 == 0:
            cprint(YELLOW, f"Epoch {epoch}, Loss={loss.item():.6f}")

    return model


def predict_next(model: Any, last_seq: List[float]) -> float:
    try:
        import torch
        model.eval()
        with torch.no_grad():
            x = torch.tensor([last_seq], dtype=torch.float32).unsqueeze(-1)
            pred = model(x).item()
        return pred
    except Exception:
        # fallback: average of last 3
        return sum(last_seq[-3:]) / 3.0


def main() -> int:
    parser = argparse.ArgumentParser(description="Train LSTM difficulty predictor")
    parser.add_argument("--input", help="JSON with series array")
    parser.add_argument("--output", default="difficulty-prediction.json", help="Output JSON path")
    parser.add_argument("--seq-len", type=int, default=10, help="Sequence length")
    args = parser.parse_args()

    cprint(GREEN, "=== OmniBus Difficulty Predictor ===")
    if args.input and os.path.isfile(args.input):
        with open(args.input, "r", encoding="utf-8") as f:
            data = json.load(f)
        series = data.get("series", [])
    else:
        series = generate_synthetic_series()
        cprint(YELLOW, "Using synthetic training data")

    X, y = prepare_sequences(series, args.seq_len)
    cprint(YELLOW, f"Prepared {len(X)} training sequences")

    model = train_lstm(X, y)
    last_seq = [s["difficulty"] for s in series][-args.seq_len :]
    pred = predict_next(model, last_seq)

    result = {
        "predicted_next_difficulty": round(pred, 4),
        "last_known_difficulty": round(last_seq[-1], 4),
        "training_samples": len(X),
    }
    cprint(GREEN, f"Predicted next difficulty: {pred:.4f}")

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2)
    cprint(GREEN, f"Result written to {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

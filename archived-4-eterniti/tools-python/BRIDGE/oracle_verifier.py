#!/usr/bin/env python3
"""
oracle_verifier.py - Oracle Data Verifier v1.0

Verifică datele de la oracles pentru OmniBus:
  - Price feed validation (outlier detection)
  - Multi-oracle consensus
  - Stale data detection
  - Manipulation detection
  - Chainlink, Band Protocol, API3 support

Usage:
  python tools/BRIDGE/oracle_verifier.py --price BTC --value 45000
  python tools/BRIDGE/oracle_verifier.py --check-stale
  python tools/BRIDGE/oracle_verifier.py --consensus BTC
"""

import sys
import json
import time
import statistics
import argparse
from pathlib import Path
from dataclasses import dataclass, field
from typing import List, Dict, Optional, Tuple
from datetime import datetime, timedelta
from enum import Enum

ROOT = Path(__file__).parent.parent.parent

class OracleSource(Enum):
    CHAINLINK = "chainlink"
    BAND = "band"
    API3 = "api3"
    UNISWAP = "uniswap"
    CUSTOM = "custom"

class DataStatus(Enum):
    VALID = "valid"
    STALE = "stale"
    OUTLIER = "outlier"
    MANIPULATED = "manipulated"
    UNAVAILABLE = "unavailable"

@dataclass
class PriceData:
    asset: str
    price: float
    source: OracleSource
    timestamp: datetime
    confidence: float = 0.0  # 0-1
    volume_24h: float = 0.0

@dataclass
class VerificationResult:
    status: DataStatus
    message: str
    confidence: float
    sources_used: int
    price_deviation: float = 0.0
    recommended_action: str = ""


class OracleVerifier:
    """Verifies oracle data integrity."""
    
    # Configuration
    STALE_THRESHOLD_SECONDS = 3600  # 1 hour
    OUTLIER_THRESHOLD_PERCENT = 5.0  # 5% deviation
    MIN_SOURCES_FOR_CONSENSUS = 3
    
    # Asset-specific thresholds
    ASSET_THRESHOLDS = {
        "BTC": {"volatility": 0.03, "min_sources": 3},
        "ETH": {"volatility": 0.04, "min_sources": 3},
        "OMNI": {"volatility": 0.05, "min_sources": 2},
        "USDC": {"volatility": 0.001, "min_sources": 2},  # Stablecoin
        "USDT": {"volatility": 0.001, "min_sources": 2},  # Stablecoin
    }
    
    def __init__(self):
        self.price_history: Dict[str, List[PriceData]] = {}
        self.sources: Dict[str, List[OracleSource]] = {}
    
    def is_stale(self, data: PriceData) -> bool:
        """Check if price data is stale."""
        age = (datetime.now() - data.timestamp).total_seconds()
        return age > self.STALE_THRESHOLD_SECONDS
    
    def detect_outlier(self, data: PriceData, other_prices: List[float]) -> Tuple[bool, float]:
        """Detect if price is an outlier compared to other sources."""
        if len(other_prices) < 2:
            return False, 0.0
        
        median_price = statistics.median(other_prices)
        if median_price == 0:
            return False, 0.0
        
        deviation = abs(data.price - median_price) / median_price * 100
        
        # Get threshold for this asset
        thresholds = self.ASSET_THRESHOLDS.get(data.asset, {})
        max_deviation = thresholds.get("volatility", 0.05) * 100
        
        is_outlier = deviation > max_deviation
        return is_outlier, deviation
    
    def check_manipulation(self, asset: str, current_price: float) -> Tuple[bool, str]:
        """Check for potential price manipulation."""
        history = self.price_history.get(asset, [])
        
        if len(history) < 10:
            return False, "Insufficient history"
        
        # Get recent prices
        recent_prices = [p.price for p in history[-10:]]
        avg_price = statistics.mean(recent_prices)
        std_dev = statistics.stdev(recent_prices) if len(recent_prices) > 1 else 0
        
        if std_dev == 0:
            return False, "No price movement"
        
        # Check if current price is > 3 standard deviations
        z_score = abs(current_price - avg_price) / std_dev
        
        if z_score > 3:
            return True, f"Unusual price movement (z-score: {z_score:.2f})"
        
        # Check for sudden large change
        if len(recent_prices) >= 2:
            prev_price = recent_prices[-1]
            if prev_price > 0:
                change = abs(current_price - prev_price) / prev_price * 100
                if change > 20:  # 20% change in one update
                    return True, f"Sudden price change: {change:.2f}%"
        
        return False, "Normal price movement"
    
    def verify_consensus(self, prices: List[PriceData]) -> VerificationResult:
        """Verify consensus among multiple oracle sources."""
        if not prices:
            return VerificationResult(
                status=DataStatus.UNAVAILABLE,
                message="No price data available",
                confidence=0.0,
                sources_used=0
            )
        
        asset = prices[0].asset
        
        # Filter out stale data
        fresh_prices = [p for p in prices if not self.is_stale(p)]
        stale_count = len(prices) - len(fresh_prices)
        
        if len(fresh_prices) < self.MIN_SOURCES_FOR_CONSENSUS:
            return VerificationResult(
                status=DataStatus.STALE,
                message=f"Insufficient fresh data sources. Stale: {stale_count}",
                confidence=0.3,
                sources_used=len(fresh_prices)
            )
        
        # Check for outliers
        price_values = [p.price for p in fresh_prices]
        outlier_count = 0
        max_deviation = 0.0
        
        for price_data in fresh_prices:
            other_prices = [p for p in price_values if p != price_data.price]
            is_outlier, deviation = self.detect_outlier(price_data, other_prices)
            if is_outlier:
                outlier_count += 1
            max_deviation = max(max_deviation, deviation)
        
        # Remove outliers for consensus calculation
        valid_prices = []
        for p in fresh_prices:
            other_prices = [x.price for x in fresh_prices if x.price != p.price]
            is_outlier, _ = self.detect_outlier(p, other_prices)
            if not is_outlier:
                valid_prices.append(p)
        
        if len(valid_prices) < self.MIN_SOURCES_FOR_CONSENSUS:
            return VerificationResult(
                status=DataStatus.OUTLIER,
                message=f"Too many outliers ({outlier_count}). Max deviation: {max_deviation:.2f}%",
                confidence=0.4,
                sources_used=len(valid_prices),
                price_deviation=max_deviation,
                recommended_action="Investigate price sources or wait for convergence"
            )
        
        # Calculate consensus price (median)
        consensus_price = statistics.median([p.price for p in valid_prices])
        
        # Check for manipulation
        is_manipulated, manipulation_msg = self.check_manipulation(asset, consensus_price)
        
        if is_manipulated:
            return VerificationResult(
                status=DataStatus.MANIPULATED,
                message=f"Potential manipulation detected: {manipulation_msg}",
                confidence=0.2,
                sources_used=len(valid_prices),
                price_deviation=max_deviation,
                recommended_action="Pause trading, investigate immediately"
            )
        
        # Calculate confidence based on source agreement
        price_std = statistics.stdev([p.price for p in valid_prices]) if len(valid_prices) > 1 else 0
        confidence = 1.0 - min(price_std / consensus_price, 1.0) if consensus_price > 0 else 0.0
        
        return VerificationResult(
            status=DataStatus.VALID,
            message=f"Valid consensus price: ${consensus_price:,.2f}",
            confidence=confidence,
            sources_used=len(valid_prices),
            price_deviation=max_deviation,
            recommended_action="Use for on-chain operations"
        )
    
    def add_price_data(self, data: PriceData):
        """Add price data to history."""
        if data.asset not in self.price_history:
            self.price_history[data.asset] = []
        
        self.price_history[data.asset].append(data)
        
        # Keep only last 100 data points
        if len(self.price_history[data.asset]) > 100:
            self.price_history[data.asset] = self.price_history[data.asset][-100:]
    
    def get_recommended_price(self, asset: str) -> Optional[float]:
        """Get the recommended price for an asset based on verification."""
        history = self.price_history.get(asset, [])
        
        if not history:
            return None
        
        # Use only recent data
        recent = [p for p in history if not self.is_stale(p)]
        if len(recent) < self.MIN_SOURCES_FOR_CONSENSUS:
            # Fall back to median of all recent data
            recent = history[-10:]
        
        if not recent:
            return None
        
        return statistics.median([p.price for p in recent])
    
    def generate_report(self) -> Dict:
        """Generate verification report for all tracked assets."""
        report = {
            "generated_at": datetime.now().isoformat(),
            "assets": {}
        }
        
        for asset in self.price_history:
            history = self.price_history[asset]
            if not history:
                continue
            
            recent = [p for p in history[-10:] if not self.is_stale(p)]
            
            if recent:
                result = self.verify_consensus(recent)
                report["assets"][asset] = {
                    "current_price": self.get_recommended_price(asset),
                    "status": result.status.value,
                    "confidence": round(result.confidence, 4),
                    "sources": result.sources_used,
                    "message": result.message
                }
        
        return report


def main():
    parser = argparse.ArgumentParser(description="Oracle Data Verifier")
    parser.add_argument("--price", help="Asset symbol (BTC, ETH, etc)")
    parser.add_argument("--value", type=float, help="Price value to verify")
    parser.add_argument("--check-stale", action="store_true", help="Check for stale data")
    parser.add_argument("--consensus", help="Check consensus for asset")
    parser.add_argument("--report", action="store_true", help="Generate full report")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    args = parser.parse_args()
    
    print("\n" + "=" * 60)
    print("  OmniBus Oracle Data Verifier")
    print("=" * 60)
    
    verifier = OracleVerifier()
    
    # Simulate some example data for demonstration
    if args.consensus or args.report:
        # Add simulated data for BTC
        for i in range(5):
            verifier.add_price_data(PriceData(
                asset="BTC",
                price=45000 + (i * 100),  # Small variations
                source=OracleSource.CHAINLINK if i % 2 == 0 else OracleSource.BAND,
                timestamp=datetime.now() - timedelta(minutes=i*5),
                confidence=0.95
            ))
        
        # Add simulated data for ETH
        for i in range(5):
            verifier.add_price_data(PriceData(
                asset="ETH",
                price=3000 + (i * 10),
                source=OracleSource.CHAINLINK if i % 2 == 0 else OracleSource.API3,
                timestamp=datetime.now() - timedelta(minutes=i*5),
                confidence=0.93
            ))
    
    if args.consensus:
        print(f"\nChecking consensus for {args.consensus}...")
        history = verifier.price_history.get(args.consensus, [])
        result = verifier.verify_consensus(history)
        
        print(f"\nStatus: {result.status.value.upper()}")
        print(f"Message: {result.message}")
        print(f"Confidence: {result.confidence:.2%}")
        print(f"Sources: {result.sources_used}")
        if result.price_deviation > 0:
            print(f"Max Deviation: {result.price_deviation:.2f}%")
        if result.recommended_action:
            print(f"Action: {result.recommended_action}")
    
    elif args.report:
        report = verifier.generate_report()
        
        if args.json:
            print(json.dumps(report, indent=2))
        else:
            print("\nOracle Verification Report:")
            print("-" * 60)
            for asset, data in report.get("assets", {}).items():
                print(f"\n{asset}:")
                print(f"  Price: ${data.get('current_price'):,.2f}" if data.get('current_price') else "  Price: N/A")
                print(f"  Status: {data.get('status', 'unknown')}")
                print(f"  Confidence: {data.get('confidence', 0):.2%}")
                print(f"  Sources: {data.get('sources', 0)}")
    
    elif args.price and args.value:
        print(f"\nVerifying {args.price} price: ${args.value:,.2f}")
        # Would verify against multiple sources in production
        print("Note: Full verification requires multiple oracle sources")
    
    else:
        parser.print_help()
    
    print("\n" + "=" * 60 + "\n")

if __name__ == "__main__":
    main()

import React, { useState, useEffect } from 'react';
import { ArrowUpRight, ArrowDownLeft, TrendingUp, TrendingDown, DollarSign, Zap } from 'lucide-react';

interface OrderBook {
  price: number;
  amount: number;
  total: number;
}

interface Trade {
  id: string;
  type: 'BUY' | 'SELL';
  price: number;
  amount: number;
  timestamp: string;
  status: 'OPEN' | 'FILLED' | 'CANCELLED';
}

interface Wallet {
  BTC: number;
  USDT: number;
  SAT: number;
}

const Trading: React.FC<{ pair?: string }> = ({ pair = 'BTC-USDT' }) => {
  const [orderType, setOrderType] = useState<'BUY' | 'SELL'>('BUY');
  const [orderPrice, setOrderPrice] = useState<string>('');
  const [orderAmount, setOrderAmount] = useState<string>('');
  const [currentPrice, setCurrentPrice] = useState(45250);
  const [priceChange, setPriceChange] = useState(2.5);
  const [volume24h, setVolume24h] = useState(1250000);

  const [wallet, setWallet] = useState<Wallet>({
    BTC: 5.25,
    USDT: 125000,
    SAT: 525000000,
  });

  const [orders, setOrders] = useState<Trade[]>([
    {
      id: 'ORD001',
      type: 'BUY',
      price: 45000,
      amount: 0.5,
      timestamp: '2026-03-18 12:30:45',
      status: 'FILLED',
    },
    {
      id: 'ORD002',
      type: 'SELL',
      price: 45500,
      amount: 0.25,
      timestamp: '2026-03-18 11:15:20',
      status: 'FILLED',
    },
  ]);

  const [bids, setBids] = useState<OrderBook[]>([
    { price: 45240, amount: 2.5, total: 113100 },
    { price: 45220, amount: 1.8, total: 81396 },
    { price: 45200, amount: 3.2, total: 144640 },
    { price: 45180, amount: 0.9, total: 40662 },
    { price: 45160, amount: 4.1, total: 185156 },
  ]);

  const [asks, setAsks] = useState<OrderBook[]>([
    { price: 45260, amount: 1.2, total: 54312 },
    { price: 45280, amount: 2.8, total: 126784 },
    { price: 45300, amount: 0.6, total: 27180 },
    { price: 45320, amount: 3.5, total: 158620 },
    { price: 45340, amount: 1.9, total: 86146 },
  ]);

  // Simulate price updates
  useEffect(() => {
    const interval = setInterval(() => {
      const change = (Math.random() - 0.5) * 100;
      setCurrentPrice(prev => {
        const newPrice = prev + change;
        return Math.max(newPrice, 40000);
      });
      setPriceChange(prev => prev + (Math.random() - 0.5) * 0.5);
    }, 3000);
    return () => clearInterval(interval);
  }, []);

  const handlePlaceOrder = () => {
    if (!orderPrice || !orderAmount) {
      alert('Please enter price and amount');
      return;
    }

    const newOrder: Trade = {
      id: `ORD${Math.random().toString().slice(2, 8)}`,
      type: orderType,
      price: parseFloat(orderPrice),
      amount: parseFloat(orderAmount),
      timestamp: new Date().toLocaleString(),
      status: 'OPEN',
    };

    setOrders([newOrder, ...orders]);

    // Update wallet balances
    if (orderType === 'BUY') {
      const totalUSDT = parseFloat(orderPrice) * parseFloat(orderAmount);
      setWallet(prev => ({
        ...prev,
        BTC: prev.BTC + parseFloat(orderAmount),
        USDT: prev.USDT - totalUSDT,
      }));
    } else {
      const totalUSDT = parseFloat(orderPrice) * parseFloat(orderAmount);
      setWallet(prev => ({
        ...prev,
        BTC: prev.BTC - parseFloat(orderAmount),
        USDT: prev.USDT + totalUSDT,
      }));
    }

    setOrderPrice('');
    setOrderAmount('');
  };

  const totalOrderValue = orderPrice && orderAmount
    ? (parseFloat(orderPrice) * parseFloat(orderAmount)).toFixed(2)
    : '0.00';

  return (
    <div className="min-h-screen bg-gradient-to-br from-slate-900 to-slate-800 text-white">
      {/* Header */}
      <div className="bg-slate-800 border-b border-slate-700 p-6">
        <div className="max-w-7xl mx-auto">
          <div className="flex items-center justify-between mb-6">
            <div className="flex items-center gap-4">
              <h1 className="text-4xl font-bold">{pair}</h1>
              <div className={`flex items-center gap-2 px-4 py-2 rounded-lg ${
                priceChange >= 0 ? 'bg-green-900' : 'bg-red-900'
              }`}>
                {priceChange >= 0 ? (
                  <TrendingUp className="w-5 h-5 text-green-400" />
                ) : (
                  <TrendingDown className="w-5 h-5 text-red-400" />
                )}
                <span className={priceChange >= 0 ? 'text-green-400' : 'text-red-400'}>
                  {priceChange >= 0 ? '+' : ''}{priceChange.toFixed(2)}%
                </span>
              </div>
            </div>
            <div className="text-right">
              <div className="text-5xl font-bold text-yellow-400">
                ${currentPrice.toFixed(2)}
              </div>
              <div className="text-gray-400 mt-2">
                24h Volume: ${(volume24h / 1000000).toFixed(2)}M
              </div>
            </div>
          </div>
        </div>
      </div>

      {/* Main Content */}
      <div className="max-w-7xl mx-auto p-6">
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
          {/* Left: Order Form & Wallet */}
          <div className="lg:col-span-1 space-y-6">
            {/* Trading Form */}
            <div className="bg-slate-700 rounded-lg p-6">
              <h2 className="text-2xl font-bold mb-6">Place Order</h2>

              {/* Order Type Selector */}
              <div className="flex gap-4 mb-6">
                <button
                  onClick={() => setOrderType('BUY')}
                  className={`flex-1 py-3 rounded-lg font-bold transition-colors ${
                    orderType === 'BUY'
                      ? 'bg-green-600 text-white'
                      : 'bg-slate-600 text-gray-300 hover:bg-slate-500'
                  }`}
                >
                  <ArrowDownLeft className="w-5 h-5 inline mr-2" />
                  BUY
                </button>
                <button
                  onClick={() => setOrderType('SELL')}
                  className={`flex-1 py-3 rounded-lg font-bold transition-colors ${
                    orderType === 'SELL'
                      ? 'bg-red-600 text-white'
                      : 'bg-slate-600 text-gray-300 hover:bg-slate-500'
                  }`}
                >
                  <ArrowUpRight className="w-5 h-5 inline mr-2" />
                  SELL
                </button>
              </div>

              {/* Price Input */}
              <div className="mb-4">
                <label className="block text-gray-300 text-sm font-bold mb-2">
                  Price (USDT)
                </label>
                <input
                  type="number"
                  value={orderPrice}
                  onChange={(e) => setOrderPrice(e.target.value)}
                  placeholder={currentPrice.toFixed(2)}
                  className="w-full px-4 py-3 bg-slate-600 border border-slate-500 rounded-lg text-white placeholder-gray-400 focus:outline-none focus:border-blue-400"
                />
              </div>

              {/* Amount Input */}
              <div className="mb-4">
                <label className="block text-gray-300 text-sm font-bold mb-2">
                  Amount (BTC)
                </label>
                <input
                  type="number"
                  value={orderAmount}
                  onChange={(e) => setOrderAmount(e.target.value)}
                  placeholder="0.00"
                  className="w-full px-4 py-3 bg-slate-600 border border-slate-500 rounded-lg text-white placeholder-gray-400 focus:outline-none focus:border-blue-400"
                />
              </div>

              {/* Quick Buttons */}
              <div className="grid grid-cols-4 gap-2 mb-4">
                {['25%', '50%', '75%', '100%'].map((percent) => (
                  <button
                    key={percent}
                    onClick={() => {
                      const maxAmount = orderType === 'BUY'
                        ? (wallet.USDT / parseFloat(orderPrice || currentPrice.toString()))
                        : wallet.BTC;
                      const amount = maxAmount * (parseInt(percent) / 100);
                      setOrderAmount(amount.toFixed(8));
                    }}
                    className="py-2 bg-slate-600 hover:bg-slate-500 rounded text-xs font-bold"
                  >
                    {percent}
                  </button>
                ))}
              </div>

              {/* Total */}
              <div className="bg-slate-600 rounded-lg p-4 mb-6">
                <div className="flex justify-between mb-2">
                  <span className="text-gray-300">Total</span>
                  <span className="font-bold text-lg">${totalOrderValue}</span>
                </div>
                <div className="flex justify-between text-sm text-gray-400">
                  <span>Fee (0.1%)</span>
                  <span>${(parseFloat(totalOrderValue) * 0.001).toFixed(2)}</span>
                </div>
              </div>

              {/* Place Order Button */}
              <button
                onClick={handlePlaceOrder}
                className={`w-full py-4 rounded-lg font-bold text-lg transition-colors ${
                  orderType === 'BUY'
                    ? 'bg-green-600 hover:bg-green-700 text-white'
                    : 'bg-red-600 hover:bg-red-700 text-white'
                }`}
              >
                {orderType === 'BUY' ? 'Buy BTC' : 'Sell BTC'}
              </button>
            </div>

            {/* Wallet Balance */}
            <div className="bg-slate-700 rounded-lg p-6">
              <h3 className="text-xl font-bold mb-4 flex items-center gap-2">
                <DollarSign className="w-5 h-5 text-yellow-400" />
                Wallet
              </h3>
              <div className="space-y-4">
                <div className="bg-slate-600 rounded-lg p-4">
                  <div className="text-gray-400 text-sm mb-1">Bitcoin</div>
                  <div className="text-3xl font-bold text-orange-400">
                    {wallet.BTC.toFixed(4)} BTC
                  </div>
                  <div className="text-gray-400 text-sm mt-1">
                    ≈ ${(wallet.BTC * currentPrice).toFixed(2)}
                  </div>
                </div>
                <div className="bg-slate-600 rounded-lg p-4">
                  <div className="text-gray-400 text-sm mb-1">USDT</div>
                  <div className="text-3xl font-bold text-green-400">
                    ${wallet.USDT.toFixed(2)}
                  </div>
                </div>
                <div className="bg-slate-600 rounded-lg p-4">
                  <div className="text-gray-400 text-sm mb-1">OmniBus SAT</div>
                  <div className="text-3xl font-bold text-yellow-400">
                    {wallet.SAT.toLocaleString()} SAT
                  </div>
                </div>
              </div>
            </div>
          </div>

          {/* Center & Right: Order Book & Trades */}
          <div className="lg:col-span-2 space-y-6">
            {/* Order Book */}
            <div className="grid grid-cols-2 gap-6">
              {/* Bids (Buy Orders) */}
              <div className="bg-slate-700 rounded-lg p-6">
                <h3 className="text-lg font-bold mb-4 text-green-400">Bids (Buy Orders)</h3>
                <div className="space-y-2 max-h-64 overflow-y-auto">
                  <div className="grid grid-cols-3 gap-2 text-gray-400 text-sm mb-3 pb-2 border-b border-slate-600">
                    <span>Price</span>
                    <span>Amount</span>
                    <span>Total</span>
                  </div>
                  {bids.map((bid, idx) => (
                    <div key={idx} className="grid grid-cols-3 gap-2 text-sm hover:bg-slate-600 p-2 rounded cursor-pointer transition-colors">
                      <span className="text-green-400">${bid.price.toFixed(2)}</span>
                      <span className="text-gray-300">{bid.amount.toFixed(4)}</span>
                      <span className="text-gray-300">${bid.total.toFixed(0)}</span>
                    </div>
                  ))}
                </div>
              </div>

              {/* Asks (Sell Orders) */}
              <div className="bg-slate-700 rounded-lg p-6">
                <h3 className="text-lg font-bold mb-4 text-red-400">Asks (Sell Orders)</h3>
                <div className="space-y-2 max-h-64 overflow-y-auto">
                  <div className="grid grid-cols-3 gap-2 text-gray-400 text-sm mb-3 pb-2 border-b border-slate-600">
                    <span>Price</span>
                    <span>Amount</span>
                    <span>Total</span>
                  </div>
                  {asks.map((ask, idx) => (
                    <div key={idx} className="grid grid-cols-3 gap-2 text-sm hover:bg-slate-600 p-2 rounded cursor-pointer transition-colors">
                      <span className="text-red-400">${ask.price.toFixed(2)}</span>
                      <span className="text-gray-300">{ask.amount.toFixed(4)}</span>
                      <span className="text-gray-300">${ask.total.toFixed(0)}</span>
                    </div>
                  ))}
                </div>
              </div>
            </div>

            {/* Trading History */}
            <div className="bg-slate-700 rounded-lg p-6">
              <h3 className="text-xl font-bold mb-4 flex items-center gap-2">
                <Zap className="w-5 h-5 text-yellow-400" />
                Your Orders
              </h3>
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead className="border-b border-slate-600">
                    <tr>
                      <th className="text-left py-3 px-4 text-gray-400">Order ID</th>
                      <th className="text-left py-3 px-4 text-gray-400">Type</th>
                      <th className="text-left py-3 px-4 text-gray-400">Price</th>
                      <th className="text-left py-3 px-4 text-gray-400">Amount</th>
                      <th className="text-left py-3 px-4 text-gray-400">Total</th>
                      <th className="text-left py-3 px-4 text-gray-400">Time</th>
                      <th className="text-left py-3 px-4 text-gray-400">Status</th>
                    </tr>
                  </thead>
                  <tbody>
                    {orders.map((order) => (
                      <tr key={order.id} className="border-b border-slate-600 hover:bg-slate-600 transition-colors">
                        <td className="py-3 px-4 font-mono text-blue-400">{order.id}</td>
                        <td className="py-3 px-4">
                          <span className={`px-3 py-1 rounded text-xs font-bold ${
                            order.type === 'BUY'
                              ? 'bg-green-900 text-green-400'
                              : 'bg-red-900 text-red-400'
                          }`}>
                            {order.type}
                          </span>
                        </td>
                        <td className="py-3 px-4">${order.price.toFixed(2)}</td>
                        <td className="py-3 px-4">{order.amount.toFixed(4)} BTC</td>
                        <td className="py-3 px-4 font-bold">${(order.price * order.amount).toFixed(2)}</td>
                        <td className="py-3 px-4 text-gray-400 text-xs">{order.timestamp}</td>
                        <td className="py-3 px-4">
                          <span className={`px-2 py-1 rounded text-xs font-bold ${
                            order.status === 'FILLED'
                              ? 'bg-green-900 text-green-400'
                              : order.status === 'OPEN'
                                ? 'bg-blue-900 text-blue-400'
                                : 'bg-gray-900 text-gray-400'
                          }`}>
                            {order.status}
                          </span>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};

export default Trading;

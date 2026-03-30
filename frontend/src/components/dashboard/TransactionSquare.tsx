interface TransactionSquareProps {
  amount: number;
  index: number;
  isPending?: boolean;
}

function amountToColor(amount: number): string {
  if (amount <= 0) return "#5470c6";           // coinbase/unknown → blue
  if (amount < 100_000_000) return "#5470c6";   // < 0.1 OMNI → light blue
  if (amount < 1_000_000_000) return "#4a90d9"; // < 1 OMNI → blue
  if (amount < 10_000_000_000) return "#7b61ff"; // < 10 OMNI → purple
  return "#00b3a4";                               // >= 10 OMNI → green (whale)
}

export function TransactionSquare({ amount, index, isPending }: TransactionSquareProps) {
  const color = amountToColor(amount);
  const delay = Math.min(index * 20, 300);

  return (
    <div
      className="rounded-sm transition-all duration-300"
      style={{
        width: 12,
        height: 12,
        backgroundColor: color,
        opacity: isPending ? 0.7 : 1,
        animation: `fillIn 0.3s ease-out ${delay}ms both`,
      }}
      title={`${(amount / 1e9).toFixed(4)} OMNI`}
    />
  );
}

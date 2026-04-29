import { createContext, useContext, useEffect, useState } from "react";

/**
 * Cycle through plasma 'slots' so only ONE orb is visible at a time.
 *
 * Order matches the visual top-to-bottom of the dashboard:
 *   slot 0..4 -> the five StatsBar cards (Block Height, Mempool,
 *                Difficulty, Total Mined, Reward/Block)
 *   slot 5    -> the MempoolBlockStrip 'Next' pending card
 *   slot 6    -> the most-recent confirmed block card
 *
 * Each slot is held for SLOT_MS, then we advance. After the last slot
 * we wrap back to 0 and the wave repeats.
 */
/** Total = 5 header logos + 5 stats cards + 2 mempool/block = 12. */
const TOTAL_SLOTS = 12;
const SLOT_MS = 10_000;

const PlasmaSlotContext = createContext<number>(-1);

export function PlasmaSlotProvider({ children }: { children: React.ReactNode }) {
  const [active, setActive] = useState(0);
  useEffect(() => {
    const id = setInterval(() => {
      setActive((prev) => (prev + 1) % TOTAL_SLOTS);
    }, SLOT_MS);
    return () => clearInterval(id);
  }, []);
  return (
    <PlasmaSlotContext.Provider value={active}>{children}</PlasmaSlotContext.Provider>
  );
}

/** Returns true if THIS slot is currently the live plasma. */
export function useIsPlasmaActive(slot: number): boolean {
  const active = useContext(PlasmaSlotContext);
  return active === slot;
}

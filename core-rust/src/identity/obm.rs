//! OBM — OmniBus Binary Map. One byte of badges, derived live.
//!
//! Bit positions are part of the wire format. Append new bits at higher
//! indices only; never reorder.

/// Reputation cup scaling: stored values are multiplied by 100.
pub const CUP_SCALE: u32 = 100;
pub const CUP_CAP_STORED: u32 = 100 * CUP_SCALE; // 10_000 = 100.00

/// Threshold (stored ×100) at which a cup badge bit lights up.
pub const BADGE_THRESHOLD_STORED: u32 = 50 * CUP_SCALE;

pub type Obm = u8;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ReputationCups {
    pub love_stored: u32,
    pub food_stored: u32,
    pub rent_stored: u32,
    pub vacation_stored: u32,
}

impl ReputationCups {
    pub fn has_satoshi_badge(&self) -> bool {
        self.love_stored >= CUP_CAP_STORED
            && self.food_stored >= CUP_CAP_STORED
            && self.rent_stored >= CUP_CAP_STORED
            && self.vacation_stored >= CUP_CAP_STORED
    }
}

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ObmBit {
    LoveBadge = 0,
    FoodBadge = 1,
    RentBadge = 2,
    VacationBadge = 3,
    HasPqKey = 4,
    HasDnsName = 5,
    IsValidator = 6,
    IsZenTier = 7,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct ObmInputs {
    pub cups: ReputationCups,
    pub has_pq_key: bool,
    pub has_dns_name: bool,
    pub is_validator: bool,
}

#[inline]
fn bit(b: ObmBit) -> u8 {
    1u8 << (b as u8)
}

pub fn compute_obm(inputs: ObmInputs) -> Obm {
    let mut byte = 0u8;
    if inputs.cups.love_stored >= BADGE_THRESHOLD_STORED {
        byte |= bit(ObmBit::LoveBadge);
    }
    if inputs.cups.food_stored >= BADGE_THRESHOLD_STORED {
        byte |= bit(ObmBit::FoodBadge);
    }
    if inputs.cups.rent_stored >= BADGE_THRESHOLD_STORED {
        byte |= bit(ObmBit::RentBadge);
    }
    if inputs.cups.vacation_stored >= BADGE_THRESHOLD_STORED {
        byte |= bit(ObmBit::VacationBadge);
    }
    if inputs.has_pq_key {
        byte |= bit(ObmBit::HasPqKey);
    }
    if inputs.has_dns_name {
        byte |= bit(ObmBit::HasDnsName);
    }
    if inputs.is_validator {
        byte |= bit(ObmBit::IsValidator);
    }
    if inputs.cups.has_satoshi_badge() {
        byte |= bit(ObmBit::IsZenTier);
    }
    byte
}

pub fn has(obm: Obm, b: ObmBit) -> bool {
    (obm & bit(b)) != 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fresh_wallet_is_zero() {
        assert_eq!(compute_obm(ObmInputs::default()), 0);
    }

    #[test]
    fn love_bit_at_exactly_5000() {
        let cups = ReputationCups { love_stored: BADGE_THRESHOLD_STORED, ..Default::default() };
        let o = compute_obm(ObmInputs { cups, ..Default::default() });
        assert!(has(o, ObmBit::LoveBadge));
        assert!(!has(o, ObmBit::FoodBadge));
    }

    #[test]
    fn love_dark_just_below() {
        let cups = ReputationCups { love_stored: BADGE_THRESHOLD_STORED - 1, ..Default::default() };
        assert!(!has(compute_obm(ObmInputs { cups, ..Default::default() }), ObmBit::LoveBadge));
    }

    #[test]
    fn all_flags_pack_to_ff() {
        let cups = ReputationCups {
            love_stored: CUP_CAP_STORED,
            food_stored: CUP_CAP_STORED,
            rent_stored: CUP_CAP_STORED,
            vacation_stored: CUP_CAP_STORED,
        };
        let o = compute_obm(ObmInputs {
            cups,
            has_pq_key: true,
            has_dns_name: true,
            is_validator: true,
        });
        assert_eq!(o, 0xFF);
    }
}

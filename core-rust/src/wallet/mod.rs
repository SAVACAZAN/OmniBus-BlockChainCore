// wallet/ — High-level HD wallet operations on top of crypto/.
// Mirrors core/wallet.zig domain layout:
//   coin_type 777 = OMNI native        (ob1q... bech32)
//   coin_type 778 = LOVE soulbound     (ob_k1_... base58check)
//   coin_type 779 = FOOD soulbound     (ob_f5_... base58check)
//   coin_type 780 = RENT soulbound     (ob_d5_... base58check)
//   coin_type 781 = VACATION soulbound (ob_s3_... base58check)
//   coin_type 60  = EVM (Ethereum-compatible 0x... checksum)

pub mod hd;
pub mod address;

#[allow(unused_imports)]
pub use hd::HdWallet;
#[allow(unused_imports)]
pub use address::{Address, AddressKind, evm_checksum_address};

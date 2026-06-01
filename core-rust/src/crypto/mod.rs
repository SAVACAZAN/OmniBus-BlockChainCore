// crypto/ — Port of core/{secp256k1,bip32_wallet,bech32,ripemd160,pq_crypto}.zig
// to Rust. Outputs must be byte-identical to the Zig sibling implementation:
// same mnemonic + path -> same compressed pubkey, hash160, ob1q... bech32,
// and 0x... EVM checksum addresses.
//
// See:
//   ../../core/secp256k1.zig
//   ../../core/bip32_wallet.zig
//   ../../core/bech32.zig
//   ../../core/ripemd160.zig
//   ../../core/wallet.zig
//   ../../core/pq_crypto.zig  (stubbed here — gated `pq` feature)

pub mod secp256k1;
pub mod bip32;
pub mod bech32;
pub mod ripemd160;
pub mod pq;

#[allow(unused_imports)]
pub use bech32::{encode_ob_address, decode_ob_address, OB_HRP};
#[allow(unused_imports)]
pub use bip32::{Bip32Wallet, Network, derive_pq_seed, PQ_HKDF_SALT};
#[allow(unused_imports)]
pub use secp256k1::{private_key_to_public_key, private_key_to_hash160, private_key_to_uncompressed};
#[allow(unused_imports)]
pub use ripemd160::hash160;

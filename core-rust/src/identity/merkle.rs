//! Fixed-arity SHA-256 Merkle tree (port of Zig `id_merkle.zig`).
//!
//! Domain separation: leaves prefixed with 0x00, internal nodes with 0x01.
//! Odd leaves are duplicated to keep the tree balanced — byte-identical
//! semantics to the Zig implementation so root hashes match across nodes.

use sha2::{Digest, Sha256};

pub const HASH_SIZE: usize = 32;
pub type Hash = [u8; HASH_SIZE];

pub fn hash_leaf(data: &[u8]) -> Hash {
    let mut h = Sha256::new();
    h.update([0x00u8]);
    h.update(data);
    let out = h.finalize();
    let mut r = [0u8; 32];
    r.copy_from_slice(&out);
    r
}

pub fn hash_node(left: &Hash, right: &Hash) -> Hash {
    let mut h = Sha256::new();
    h.update([0x01u8]);
    h.update(left);
    h.update(right);
    let out = h.finalize();
    let mut r = [0u8; 32];
    r.copy_from_slice(&out);
    r
}

pub fn root_of_leaf_hashes(leaves: &[Hash]) -> Hash {
    if leaves.is_empty() {
        return [0u8; HASH_SIZE];
    }
    if leaves.len() == 1 {
        return leaves[0];
    }
    let mut current: Vec<Hash> = leaves.to_vec();
    let mut level_len = current.len();
    while level_len > 1 {
        let next_len = (level_len + 1) / 2;
        for i in 0..next_len {
            let left = current[i * 2];
            let right = if i * 2 + 1 < level_len {
                current[i * 2 + 1]
            } else {
                left
            };
            current[i] = hash_node(&left, &right);
        }
        level_len = next_len;
    }
    current[0]
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProofStep {
    pub sibling: Hash,
    pub sibling_is_right: bool,
}

pub fn prove_leaf(leaves: &[Hash], leaf_index: usize) -> Result<Vec<ProofStep>, &'static str> {
    if leaf_index >= leaves.len() {
        return Err("index out of range");
    }
    if leaves.len() <= 1 {
        return Ok(vec![]);
    }
    let mut steps = Vec::new();
    let mut current: Vec<Hash> = leaves.to_vec();
    let mut idx = leaf_index;
    let mut level_len = current.len();
    while level_len > 1 {
        let sib_index = if idx % 2 == 0 { idx + 1 } else { idx - 1 };
        let sibling = if sib_index < level_len {
            current[sib_index]
        } else {
            current[idx]
        };
        steps.push(ProofStep {
            sibling,
            sibling_is_right: sib_index > idx,
        });
        let next_len = (level_len + 1) / 2;
        for i in 0..next_len {
            let left = current[i * 2];
            let right = if i * 2 + 1 < level_len {
                current[i * 2 + 1]
            } else {
                left
            };
            current[i] = hash_node(&left, &right);
        }
        idx /= 2;
        level_len = next_len;
    }
    Ok(steps)
}

pub fn verify_proof(leaf: Hash, steps: &[ProofStep], expected_root: Hash) -> bool {
    let mut current = leaf;
    for step in steps {
        current = if step.sibling_is_right {
            hash_node(&current, &step.sibling)
        } else {
            hash_node(&step.sibling, &current)
        };
    }
    current == expected_root
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn root_single_leaf_equals_leaf() {
        let leaf = hash_leaf(b"alone");
        assert_eq!(root_of_leaf_hashes(&[leaf]), leaf);
    }

    #[test]
    fn root_two_leaves_equals_hash_node() {
        let a = hash_leaf(b"a");
        let b = hash_leaf(b"b");
        assert_eq!(root_of_leaf_hashes(&[a, b]), hash_node(&a, &b));
    }

    #[test]
    fn proof_roundtrips_each_leaf_in_4() {
        let leaves = [
            hash_leaf(b"kyc"),
            hash_leaf(b"assets"),
            hash_leaf(b"rep"),
            hash_leaf(b"pq"),
        ];
        let root = root_of_leaf_hashes(&leaves);
        for i in 0..leaves.len() {
            let proof = prove_leaf(&leaves, i).unwrap();
            assert!(verify_proof(leaves[i], &proof, root));
        }
    }

    #[test]
    fn domain_separation_node_vs_untagged() {
        let a = hash_leaf(b"x");
        let b = hash_leaf(b"y");
        let root = root_of_leaf_hashes(&[a, b]);
        let mut h = Sha256::new();
        h.update(&a);
        h.update(&b);
        let untagged: Hash = h.finalize().into();
        assert_ne!(root, untagged);
    }
}

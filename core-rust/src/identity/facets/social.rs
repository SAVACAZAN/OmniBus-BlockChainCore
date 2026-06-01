//! Social Facet (leaf index 6 of master Manifest).
//!
//! Inner tree: 4 sections in FIXED order — posts, follows, reactions, handle.
//! Private posts commit `SHA-256(id || "private_post")` so the verifier
//! cannot distinguish two private posts by their leaves.

use sha2::{Digest, Sha256};

use crate::identity::merkle::{self, Hash};

#[derive(Clone, Debug)]
pub struct PostRef {
    pub id_hash: [u8; 32],
    pub timestamp_unix_s: u64,
    pub is_public: bool,
}

#[derive(Clone, Debug)]
pub struct SocialFacet {
    pub posts: Vec<PostRef>,
    pub follows: Vec<[u8; 20]>,
    pub reactions_count: u32,
    pub display_handle: Option<String>,
}

#[derive(Clone, Debug)]
pub struct PostProof {
    pub post: PostRef,
    pub proof: Vec<merkle::ProofStep>,
}

fn post_leaf(p: &PostRef) -> Hash {
    if p.is_public {
        let mut buf = [0u8; 40];
        buf[0..32].copy_from_slice(&p.id_hash);
        buf[32..40].copy_from_slice(&p.timestamp_unix_s.to_le_bytes());
        merkle::hash_leaf(&buf)
    } else {
        let mut inner = [0u8; 32 + 12];
        inner[0..32].copy_from_slice(&p.id_hash);
        inner[32..44].copy_from_slice(b"private_post");
        let redacted: [u8; 32] = Sha256::digest(inner).into();
        merkle::hash_leaf(&redacted)
    }
}

fn build_post_leaves(facet: &SocialFacet) -> Vec<Hash> {
    if facet.posts.is_empty() {
        return vec![merkle::hash_leaf(&[0u8; 32])];
    }
    facet.posts.iter().map(post_leaf).collect()
}

fn section_root(leaves: &[Hash]) -> Hash {
    merkle::root_of_leaf_hashes(leaves)
}

pub fn compute_social_root(facet: &SocialFacet) -> Hash {
    let post_leaves = build_post_leaves(facet);
    let posts_root = section_root(&post_leaves);

    let follows_root = if facet.follows.is_empty() {
        merkle::hash_leaf(&[0u8; 32])
    } else {
        let leaves: Vec<Hash> = facet.follows.iter().map(|f| merkle::hash_leaf(f)).collect();
        section_root(&leaves)
    };

    let rx_buf = facet.reactions_count.to_le_bytes();
    let reactions_leaf = merkle::hash_leaf(&rx_buf);

    let handle_leaf = match &facet.display_handle {
        Some(h) => merkle::hash_leaf(h.as_bytes()),
        None => merkle::hash_leaf(&[0u8; 32]),
    };

    merkle::root_of_leaf_hashes(&[posts_root, follows_root, reactions_leaf, handle_leaf])
}

pub fn prove_post(facet: &SocialFacet, post_index: usize) -> Result<PostProof, &'static str> {
    if post_index >= facet.posts.len() {
        return Err("index out of range");
    }
    let leaves = build_post_leaves(facet);
    let steps = merkle::prove_leaf(&leaves, post_index)?;
    Ok(PostProof {
        post: facet.posts[post_index].clone(),
        proof: steps,
    })
}

/// Verifies the proof against the posts SUB-ROOT. Caller still must thread
/// that sub-root into the top-level 4-section tree to bind to facet_root —
/// same semantics as Zig.
pub fn verify_post(proof: &PostProof, posts_subroot: Hash) -> bool {
    let leaf = post_leaf(&proof.post);
    merkle::verify_proof(leaf, &proof.proof, posts_subroot)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_post(seed: u8, public: bool) -> PostRef {
        let mut id = [0u8; 32];
        for (i, b) in id.iter_mut().enumerate() {
            *b = seed ^ (i as u8);
        }
        PostRef {
            id_hash: id,
            timestamp_unix_s: 1_700_000_000 + seed as u64,
            is_public: public,
        }
    }

    #[test]
    fn deterministic_root() {
        let f = SocialFacet {
            posts: vec![sample_post(1, true), sample_post(2, false)],
            follows: vec![[0xAA; 20], [0xBB; 20]],
            reactions_count: 42,
            display_handle: Some("alice".into()),
        };
        assert_eq!(compute_social_root(&f), compute_social_root(&f));
    }

    #[test]
    fn empty_root_is_nonzero() {
        let f = SocialFacet {
            posts: vec![],
            follows: vec![],
            reactions_count: 0,
            display_handle: None,
        };
        assert_ne!(compute_social_root(&f), [0u8; 32]);
    }

    #[test]
    fn prove_post_roundtrip() {
        let f = SocialFacet {
            posts: vec![sample_post(1, true), sample_post(2, false), sample_post(3, true), sample_post(4, true)],
            follows: vec![],
            reactions_count: 0,
            display_handle: None,
        };
        let posts_root = merkle::root_of_leaf_hashes(&build_post_leaves(&f));
        let p = prove_post(&f, 2).unwrap();
        assert!(verify_post(&p, posts_root));

        let mut bad = p.clone();
        bad.post.timestamp_unix_s ^= 1;
        assert!(!verify_post(&bad, posts_root));
    }
}

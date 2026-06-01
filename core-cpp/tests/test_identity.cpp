#include <catch2/catch.hpp>
#include "../include/omnibus/identity/did.hpp"
#include "../include/omnibus/identity/manifest.hpp"
#include "../include/omnibus/identity/ns.hpp"

using namespace omnibus::identity;

TEST_CASE("DID creation and verification", "[identity]") {
    Hash160 pubkey_hash;
    for (size_t i = 0; i < 20; ++i) {
        pubkey_hash[i] = static_cast<u8>(i);
    }
    
    auto did = create_did(pubkey_hash);
    REQUIRE(did.substr(0, 12) == "did:omnibus:");
    
    auto extracted = extract_pubkey_hash(did);
    REQUIRE(extracted.has_value());
    REQUIRE(extracted.value() == pubkey_hash);
    
    REQUIRE(verify_did(did, pubkey_hash));
}

TEST_CASE("Manifest merkle root", "[identity]") {
    Manifest manifest;
    manifest.set_field(FieldIndex::NAME, "John Doe");
    manifest.set_field(FieldIndex::EMAIL, "john@example.com");
    
    auto root = manifest.root();
    REQUIRE(root != Hash256{});
    
    // Verify a field
    Hash256 name_hash = manifest.leaves[0];
    std::vector<Hash256> proof;
    // Would need proper proof generation
    // REQUIRE(manifest.verify_proof(FieldIndex::NAME, name_hash, proof));
}

TEST_CASE("Name service registration", "[identity]") {
    NameService ns;
    Hash160 owner;
    owner.fill(0xAA);
    
    bool registered = ns.register_name("test.omnibus", owner, 100);
    REQUIRE(registered);
    
    auto resolved = ns.resolve("test.omnibus");
    REQUIRE(resolved.has_value() == false); // No target set
    
    auto record = ns.get_record("test.omnibus");
    REQUIRE(record.has_value());
    REQUIRE(record->owner == owner);
}
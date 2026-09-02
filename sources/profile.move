// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Profile metadata object.
///
/// In Lens V3 every account is a smart-contract wallet (`Account.sol`)
/// because EVM EOAs cannot carry state or logic. On an object chain the
/// address itself is the identity, so all that remains is an optional
/// metadata object owned by the user. Account-manager style delegation
/// is deliberately out of scope here — it belongs to wallet
/// infrastructure (multisig, sponsored transactions), not the social
/// protocol.
module humming::profile;

use std::string::String;
use sui::clock::Clock;
use sui::event;

public struct Profile has key {
    id: UID,
    metadata_uri: String,
    created_ms: u64,
}

public struct ProfileCreated has copy, drop {
    profile: ID,
    owner: address,
}

#[allow(lint(self_transfer))]
public fun create(metadata_uri: String, clock: &Clock, ctx: &mut TxContext) {
    let profile = Profile {
        id: object::new(ctx),
        metadata_uri,
        created_ms: clock.timestamp_ms(),
    };
    event::emit(ProfileCreated { profile: object::id(&profile), owner: ctx.sender() });
    transfer::transfer(profile, ctx.sender());
}

public fun set_metadata_uri(profile: &mut Profile, metadata_uri: String) {
    profile.metadata_uri = metadata_uri;
}

public fun metadata_uri(profile: &Profile): String { profile.metadata_uri }

public fun created_ms(profile: &Profile): u64 { profile.created_ms }

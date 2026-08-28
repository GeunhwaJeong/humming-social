// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Creator preferences — serving-layer settings that belong to the
/// creator, not the platform.
///
/// "Is this profile subscriber-only?" started life as an app-server
/// flag, which contradicts the protocol's non-custodial stance: a
/// serving layer could silently flip a creator's paywall. Moving the
/// flag on-chain makes it self-sovereign — only a transaction signed
/// by the creator can change it, and any indexer can reconstruct the
/// same state from `PrefsChanged` events.
///
/// The registry is one shared object keyed by creator address. Writes
/// are rare (a settings toggle), so shared-object contention is not a
/// concern here, unlike the feed hot path.
///
/// Note these prefs *shape what a serving layer shows*; they are not
/// themselves an access-control primitive. Actual viewing rights come
/// from `subscriptions` / `paid_posts` state.
module humming::creator_prefs;

use sui::event;
use sui::table::{Self, Table};
use humming::platform::FeeConfigCap;
use humming::rules;

const EWrongVersion: u64 = 0;
const EAlreadyCurrent: u64 = 1;

public struct PrefsRegistry has key {
    id: UID,
    version: u64,
    prefs: Table<address, Prefs>,
}

public struct Prefs has store, copy, drop {
    /// All posts are subscriber-only (the serving layer gates the
    /// whole profile rather than individual paywalled posts).
    profile_locked: bool,
    /// When locked, whether non-subscribers still see per-post locked
    /// teasers (true) or only an aggregate wall (false).
    show_locked_previews: bool,
}

public struct PrefsChanged has copy, drop {
    creator: address,
    profile_locked: bool,
    show_locked_previews: bool,
}

/// Runs once — including at the package upgrade that introduces this
/// module — creating the canonical shared registry.
fun init(ctx: &mut TxContext) {
    transfer::share_object(PrefsRegistry {
        id: object::new(ctx),
        version: rules::current_version(),
        prefs: table::new(ctx),
    });
}

/// Set (or overwrite) the sender's own preferences. Self-sovereign by
/// construction: the key is `ctx.sender()`, so no third party — the
/// platform included — can write another creator's entry.
public fun set_prefs(
    registry: &mut PrefsRegistry,
    profile_locked: bool,
    show_locked_previews: bool,
    ctx: &TxContext,
) {
    assert_version(registry);
    let creator = ctx.sender();
    if (registry.prefs.contains(creator)) {
        registry.prefs.remove(creator);
    };
    registry.prefs.add(creator, Prefs { profile_locked, show_locked_previews });
    event::emit(PrefsChanged { creator, profile_locked, show_locked_previews });
}

/// A creator with no entry is open: not locked, previews on.
public fun prefs_of(registry: &PrefsRegistry, creator: address): (bool, bool) {
    if (registry.prefs.contains(creator)) {
        let p = registry.prefs.borrow(creator);
        (p.profile_locked, p.show_locked_previews)
    } else {
        (false, true)
    }
}

// === Administration (cap-gated) ===

/// Version migration, authorized by the platform admin cap — the same
/// single authority that governs `FeeConfig`.
public fun migrate(registry: &mut PrefsRegistry, _cap: &FeeConfigCap) {
    assert!(registry.version < rules::current_version(), EAlreadyCurrent);
    registry.version = rules::current_version();
}

fun assert_version(registry: &PrefsRegistry) {
    assert!(registry.version == rules::current_version(), EWrongVersion);
}

// === Test hooks ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx)
}

#[test_only]
public fun set_version_for_testing(registry: &mut PrefsRegistry, version: u64) {
    registry.version = version;
}

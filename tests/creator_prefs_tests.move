// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Tests for `humming::creator_prefs` and the owned `Profile` object.
#[test_only]
module humming::creator_prefs_tests;

use humming::creator_prefs::{Self, PrefsRegistry};
use humming::profile::{Self, Profile};
use humming::test_helpers::{str, new_clock, setup_creator_prefs};
use sui::event;
use sui::test_scenario::{Self as ts};

const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;

#[test]
fun creator_prefs_flow() {
    let mut s = ts::begin(ADMIN);
    setup_creator_prefs(&mut s);

    // Unset creators are open by default.
    s.next_tx(ALICE);
    {
        let registry = s.take_shared<PrefsRegistry>();
        let (locked, previews) = creator_prefs::prefs_of(&registry, ALICE);
        assert!(!locked && previews);
        ts::return_shared(registry);
    };

    // Alice locks her profile (aggregate wall, no per-post teasers).
    s.next_tx(ALICE);
    {
        let mut registry = s.take_shared<PrefsRegistry>();
        creator_prefs::set_prefs(&mut registry, true, false, s.ctx());
        let (locked, previews) = creator_prefs::prefs_of(&registry, ALICE);
        assert!(locked && !previews);
        ts::return_shared(registry);
    };

    // Overwrite is an update, not a duplicate; Bob stays untouched.
    s.next_tx(ALICE);
    {
        let mut registry = s.take_shared<PrefsRegistry>();
        creator_prefs::set_prefs(&mut registry, true, true, s.ctx());
        let (locked, previews) = creator_prefs::prefs_of(&registry, ALICE);
        assert!(locked && previews);
        let (bob_locked, _) = creator_prefs::prefs_of(&registry, BOB);
        assert!(!bob_locked);
        ts::return_shared(registry);
        // The overwrite emitted exactly one change event in this tx.
        assert!(event::events_by_type<creator_prefs::PrefsChanged>().length() == 1);
    };

    s.end();
}

#[test]
#[expected_failure(abort_code = 0, location = humming::creator_prefs)]
fun creator_prefs_version_gate() {
    let mut s = ts::begin(ADMIN);
    setup_creator_prefs(&mut s);

    s.next_tx(ALICE);
    let mut registry = s.take_shared<PrefsRegistry>();
    creator_prefs::set_version_for_testing(&mut registry, 0);
    creator_prefs::set_prefs(&mut registry, true, false, s.ctx());
    ts::return_shared(registry);
    s.end();
}

// === Profile ===

#[test]
fun profile_create_and_update() {
    let mut s = ts::begin(ALICE);
    let clock = new_clock(&mut s);
    profile::create(str(b"ipfs://alice-profile"), &clock, s.ctx());

    s.next_tx(ALICE);
    {
        let mut p = s.take_from_sender<Profile>();
        assert!(profile::metadata_uri(&p) == str(b"ipfs://alice-profile"));
        profile::set_metadata_uri(&mut p, str(b"ipfs://alice-v2"));
        assert!(profile::metadata_uri(&p) == str(b"ipfs://alice-v2"));
        s.return_to_sender(p);
    };

    clock.destroy_for_testing();
    s.end();
}

// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Tests for the `humming::rules` framework administration paths.
#[test_only]
module humming::rules_tests;

use humming::graph::{Self, FollowOp, Graph};
use humming::group::JoinGroupOp;
use humming::rules::{Self, RuleSet, RuleSetCap};
use humming::simple_payment_rule;
use humming::test_helpers::{str, filler_rule, setup_graph, setup_group};
use humming::token_gated_rule;
use std::string::String;
use sui::sui::SUI;
use sui::test_scenario::{Self as ts};

const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;

#[test]
fun rules_type_and_version() {
    assert!(rules::type_and_version() == str(b"Humming 1.0.0"));
}

#[test]
#[expected_failure(abort_code = 0, location = humming::rules)]
fun rules_duplicate_add_aborts() {
    let mut s = ts::begin(ADMIN);
    setup_group(&mut s);

    // Re-adding a rule must abort even under the other requiredness.
    s.next_tx(ADMIN);
    let mut set = s.take_shared<RuleSet<JoinGroupOp>>();
    let cap = s.take_from_sender<RuleSetCap>();
    token_gated_rule::add<JoinGroupOp, SUI>(&mut set, &cap, 500, true);
    token_gated_rule::add<JoinGroupOp, SUI>(&mut set, &cap, 900, false);
    s.return_to_sender(cap);
    ts::return_shared(set);
    s.end();
}

/// A `RuleSetCap` only administers the exact set it was created with —
/// here Bob tries to configure ALICE's follow rules with HIS own cap.
#[test]
#[expected_failure(abort_code = 5, location = humming::rules)]
fun rules_foreign_cap_rejected() {
    let mut s = ts::begin(ADMIN);
    setup_graph(&mut s);

    s.next_tx(ALICE);
    {
        let mut g = s.take_shared<Graph>();
        let cap = graph::create_my_follow_rules(&mut g, s.ctx());
        transfer::public_transfer(cap, ALICE);
        ts::return_shared(g);
    };
    s.next_tx(BOB);
    {
        let mut g = s.take_shared<Graph>();
        let cap = graph::create_my_follow_rules(&mut g, s.ctx());
        transfer::public_transfer(cap, BOB);
        ts::return_shared(g);
    };

    s.next_tx(BOB);
    let g = s.take_shared<Graph>();
    let alice_set_id = graph::follow_rules_of(&g, ALICE).destroy_some();
    let mut alice_set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, alice_set_id);
    let bob_cap = s.take_from_sender<RuleSetCap>();
    simple_payment_rule::add<FollowOp, SUI>(&mut alice_set, &bob_cap, 1, BOB, true);
    s.return_to_sender(bob_cap);
    ts::return_shared(alice_set);
    ts::return_shared(g);
    s.end();
}

/// Removing a rule that was never added aborts (the presence of a
/// different rule does not mask the lookup).
#[test]
#[expected_failure(abort_code = 1, location = humming::rules)]
fun rules_remove_missing_rule_aborts() {
    let mut s = ts::begin(ADMIN);
    setup_group(&mut s);

    s.next_tx(ADMIN);
    let mut set = s.take_shared<RuleSet<JoinGroupOp>>();
    let cap = s.take_from_sender<RuleSetCap>();
    simple_payment_rule::add<JoinGroupOp, SUI>(&mut set, &cap, 1000, ADMIN, true);
    token_gated_rule::remove<JoinGroupOp, SUI>(&mut set, &cap);
    s.return_to_sender(cap);
    ts::return_shared(set);
    s.end();
}

/// `MAX_RULES` (20) counts required and any-of rules together: 10 of
/// each fill the set, the 21st add aborts.
#[test]
#[expected_failure(abort_code = 4, location = humming::rules)]
fun rules_max_rules_enforced() {
    let mut s = ts::begin(ADMIN);
    setup_group(&mut s);

    s.next_tx(ADMIN);
    let mut set = s.take_shared<RuleSet<JoinGroupOp>>();
    let cap = s.take_from_sender<RuleSetCap>();
    rules::add(filler_rule<u8>(), &mut set, &cap, true, true);
    rules::add(filler_rule<u16>(), &mut set, &cap, true, true);
    rules::add(filler_rule<u32>(), &mut set, &cap, true, true);
    rules::add(filler_rule<u64>(), &mut set, &cap, true, true);
    rules::add(filler_rule<u128>(), &mut set, &cap, true, true);
    rules::add(filler_rule<u256>(), &mut set, &cap, true, true);
    rules::add(filler_rule<bool>(), &mut set, &cap, true, true);
    rules::add(filler_rule<address>(), &mut set, &cap, true, true);
    rules::add(filler_rule<ID>(), &mut set, &cap, true, true);
    rules::add(filler_rule<String>(), &mut set, &cap, true, true);
    rules::add(filler_rule<vector<u8>>(), &mut set, &cap, true, false);
    rules::add(filler_rule<vector<u16>>(), &mut set, &cap, true, false);
    rules::add(filler_rule<vector<u32>>(), &mut set, &cap, true, false);
    rules::add(filler_rule<vector<u64>>(), &mut set, &cap, true, false);
    rules::add(filler_rule<vector<u128>>(), &mut set, &cap, true, false);
    rules::add(filler_rule<vector<u256>>(), &mut set, &cap, true, false);
    rules::add(filler_rule<vector<bool>>(), &mut set, &cap, true, false);
    rules::add(filler_rule<vector<address>>(), &mut set, &cap, true, false);
    rules::add(filler_rule<vector<ID>>(), &mut set, &cap, true, false);
    rules::add(filler_rule<vector<String>>(), &mut set, &cap, true, false);
    // 21st rule: over the cap.
    rules::add(filler_rule<vector<vector<u8>>>(), &mut set, &cap, true, false);
    s.return_to_sender(cap);
    ts::return_shared(set);
    s.end();
}

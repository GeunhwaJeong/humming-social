// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Shared-object versioning: after an upgrade bumps the package
/// version, stale objects are dead until their admin migrates them.
#[test_only]
module humming::versioning_tests;

use humming::feed::{Self, Feed};
use humming::graph::{Self, Graph};
use humming::group::{Self, Group, JoinGroupOp};
use humming::namespace::{Self, Namespace};
use humming::rules::{Self, RuleSet, RuleSetCap};
use humming::test_helpers::{new_clock, setup_namespace, setup_graph, setup_feed, setup_group};
use humming::token_gated_rule;
use sui::sui::SUI;
use sui::test_scenario::{Self as ts};

const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;

#[test]
#[expected_failure(abort_code = 9, location = humming::namespace)]
fun version_gate_blocks_stale_namespace() {
    let mut s = ts::begin(ADMIN);
    setup_namespace(&mut s);

    s.next_tx(ALICE);
    let mut ns = s.take_shared<Namespace>();
    namespace::set_version_for_testing(&mut ns, 0);
    namespace::unassign_self(&mut ns, s.ctx());
    ts::return_shared(ns);
    s.end();
}

#[test]
#[expected_failure(abort_code = 11, location = humming::graph)]
fun version_gate_blocks_stale_graph() {
    let mut s = ts::begin(ADMIN);
    setup_graph(&mut s);

    s.next_tx(ALICE);
    let mut g = s.take_shared<Graph>();
    graph::set_version_for_testing(&mut g, 0);
    graph::unfollow(&mut g, BOB, s.ctx());
    ts::return_shared(g);
    s.end();
}

#[test]
#[expected_failure(abort_code = 12, location = humming::feed)]
fun version_gate_blocks_stale_feed() {
    let mut s = ts::begin(ADMIN);
    setup_feed(&mut s);

    s.next_tx(ALICE);
    let mut f = s.take_shared<Feed>();
    feed::set_version_for_testing(&mut f, 0);
    feed::delete_post(&mut f, 1, s.ctx());
    ts::return_shared(f);
    s.end();
}

#[test]
#[expected_failure(abort_code = 8, location = humming::group)]
fun version_gate_blocks_stale_group() {
    let mut s = ts::begin(ADMIN);
    setup_group(&mut s);

    s.next_tx(ALICE);
    let mut g = s.take_shared<Group>();
    group::set_version_for_testing(&mut g, 0);
    group::leave(&mut g, s.ctx());
    ts::return_shared(g);
    s.end();
}

#[test]
#[expected_failure(abort_code = 6, location = humming::rules)]
fun version_gate_blocks_stale_rule_set() {
    let mut s = ts::begin(ADMIN);
    setup_group(&mut s);

    s.next_tx(ADMIN);
    let mut set = s.take_shared<RuleSet<JoinGroupOp>>();
    let cap = s.take_from_sender<RuleSetCap>();
    rules::set_version_for_testing(&mut set, 0);
    token_gated_rule::add<JoinGroupOp, SUI>(&mut set, &cap, 500, true);
    s.return_to_sender(cap);
    ts::return_shared(set);
    s.end();
}

/// The full upgrade story on one primitive: a stale group is dead
/// until its admin migrates it, then works again at the new version.
#[test]
fun group_migrate_restores_stale_group() {
    let mut s = ts::begin(ADMIN);
    setup_group(&mut s);
    let clock = new_clock(&mut s);

    s.next_tx(ADMIN);
    {
        let mut g = s.take_shared<Group>();
        let admin_cap = s.take_from_sender<group::GroupAdminCap>();
        group::set_version_for_testing(&mut g, 0);
        group::migrate(&mut g, &admin_cap);
        assert!(group::version(&g) == rules::current_version());
        group::admin_add_member(&mut g, &admin_cap, ALICE, &clock);
        assert!(group::is_member(&g, ALICE));
        s.return_to_sender(admin_cap);
        ts::return_shared(g);
    };

    clock.destroy_for_testing();
    s.end();
}

/// Migrating an object that is already at the current version aborts —
/// migrate is an upgrade tool, not a no-op.
#[test]
#[expected_failure(abort_code = 9, location = humming::group)]
fun group_migrate_current_version_aborts() {
    let mut s = ts::begin(ADMIN);
    setup_group(&mut s);

    s.next_tx(ADMIN);
    let mut g = s.take_shared<Group>();
    let admin_cap = s.take_from_sender<group::GroupAdminCap>();
    group::migrate(&mut g, &admin_cap);
    s.return_to_sender(admin_cap);
    ts::return_shared(g);
    s.end();
}

#[test]
fun rules_migrate_restores_stale_rule_set() {
    let mut s = ts::begin(ADMIN);
    setup_group(&mut s);

    s.next_tx(ADMIN);
    {
        let mut set = s.take_shared<RuleSet<JoinGroupOp>>();
        let cap = s.take_from_sender<RuleSetCap>();
        rules::set_version_for_testing(&mut set, 0);
        rules::migrate(&mut set, &cap);
        assert!(rules::version(&set) == rules::current_version());
        token_gated_rule::add<JoinGroupOp, SUI>(&mut set, &cap, 500, true);
        assert!(rules::has_rule<JoinGroupOp, token_gated_rule::TokenGatedRule<SUI>>(&set));
        s.return_to_sender(cap);
        ts::return_shared(set);
    };

    s.end();
}

// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Tests for `humming::group`: rule-gated joining, membership admin,
/// bans, and the any-of rule semantics exercised through group joins.
#[test_only]
module humming::group_tests;

use humming::group::{Self, Group, JoinGroupOp};
use humming::platform::FeeConfig;
use humming::rules::{RuleSet, RuleSetCap};
use humming::simple_payment_rule;
use humming::test_helpers::{USDX, new_clock, setup_platform, setup_group, setup_any_of_group};
use humming::token_gated_rule;
use sui::coin;
use sui::sui::SUI;
use sui::test_scenario::{Self as ts};

const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;
const CAROL: address = @0xCA401;

#[test]
fun group_token_gated_join_and_leave() {
    let mut s = ts::begin(ADMIN);
    setup_group(&mut s);
    let clock = new_clock(&mut s);

    // Admin gates joining on holding at least 500 GEUNHWA.
    s.next_tx(ADMIN);
    {
        let mut set = s.take_shared<RuleSet<JoinGroupOp>>();
        let cap = s.take_from_sender<RuleSetCap>();
        token_gated_rule::add<JoinGroupOp, SUI>(&mut set, &cap, 500, true);
        s.return_to_sender(cap);
        ts::return_shared(set);
    };

    s.next_tx(ALICE);
    {
        let mut g = s.take_shared<Group>();
        let set = s.take_shared<RuleSet<JoinGroupOp>>();
        let holdings = coin::mint_for_testing<SUI>(600, s.ctx());
        let (ticket, mut req) = group::request_join(&g, s.ctx());
        token_gated_rule::prove(&set, &mut req, &holdings);
        group::execute_join(&mut g, &set, ticket, req, &clock);
        assert!(group::is_member(&g, ALICE));
        assert!(group::member_count(&g) == 1);
        holdings.burn_for_testing();
        ts::return_shared(g);
        ts::return_shared(set);
    };

    s.next_tx(ALICE);
    {
        let mut g = s.take_shared<Group>();
        group::leave(&mut g, s.ctx());
        assert!(!group::is_member(&g, ALICE));
        assert!(group::member_count(&g) == 0);
        ts::return_shared(g);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = 0, location = humming::token_gated_rule)]
fun group_join_with_insufficient_balance_fails() {
    let mut s = ts::begin(ADMIN);
    setup_group(&mut s);
    let clock = new_clock(&mut s);

    s.next_tx(ADMIN);
    {
        let mut set = s.take_shared<RuleSet<JoinGroupOp>>();
        let cap = s.take_from_sender<RuleSetCap>();
        token_gated_rule::add<JoinGroupOp, SUI>(&mut set, &cap, 500, true);
        s.return_to_sender(cap);
        ts::return_shared(set);
    };

    s.next_tx(ALICE);
    let mut g = s.take_shared<Group>();
    let set = s.take_shared<RuleSet<JoinGroupOp>>();
    let holdings = coin::mint_for_testing<SUI>(499, s.ctx());
    let (ticket, mut req) = group::request_join(&g, s.ctx());
    token_gated_rule::prove(&set, &mut req, &holdings);
    group::execute_join(&mut g, &set, ticket, req, &clock);
    holdings.burn_for_testing();
    ts::return_shared(g);
    ts::return_shared(set);
    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = 2, location = humming::group)]
fun group_banned_account_cannot_join() {
    let mut s = ts::begin(ADMIN);
    setup_group(&mut s);
    let clock = new_clock(&mut s);

    s.next_tx(ADMIN);
    {
        let mut g = s.take_shared<Group>();
        let admin_cap = s.take_from_sender<group::GroupAdminCap>();
        group::ban(&mut g, &admin_cap, BOB);
        assert!(group::is_banned(&g, BOB));
        s.return_to_sender(admin_cap);
        ts::return_shared(g);
    };

    s.next_tx(BOB);
    let mut g = s.take_shared<Group>();
    let set = s.take_shared<RuleSet<JoinGroupOp>>();
    let (ticket, req) = group::request_join(&g, s.ctx());
    group::execute_join(&mut g, &set, ticket, req, &clock);
    ts::return_shared(g);
    ts::return_shared(set);
    clock.destroy_for_testing();
    s.end();
}

#[test]
fun group_admin_manages_members() {
    let mut s = ts::begin(ADMIN);
    setup_group(&mut s);
    let clock = new_clock(&mut s);

    s.next_tx(ADMIN);
    {
        let mut g = s.take_shared<Group>();
        let admin_cap = s.take_from_sender<group::GroupAdminCap>();
        group::admin_add_member(&mut g, &admin_cap, ALICE, &clock);
        group::admin_add_member(&mut g, &admin_cap, BOB, &clock);
        assert!(group::member_count(&g) == 2);
        let (member_id, _) = group::membership(&g, BOB);
        assert!(member_id == 2);
        // Banning a member removes them.
        group::ban(&mut g, &admin_cap, BOB);
        assert!(!group::is_member(&g, BOB));
        assert!(group::member_count(&g) == 1);
        group::unban(&mut g, &admin_cap, BOB);
        assert!(!group::is_banned(&g, BOB));
        s.return_to_sender(admin_cap);
        ts::return_shared(g);
    };

    clock.destroy_for_testing();
    s.end();
}

// === any_of semantics ===

#[test]
fun group_any_of_either_rule_admits() {
    let mut s = ts::begin(ADMIN);
    setup_any_of_group(&mut s);
    setup_platform(&mut s);
    let clock = new_clock(&mut s);

    // Alice pays; she never proves the token rule.
    s.next_tx(ALICE);
    {
        let mut g = s.take_shared<Group>();
        let fee_config = s.take_shared<FeeConfig>();
        let set = s.take_shared<RuleSet<JoinGroupOp>>();
        let mut payment = coin::mint_for_testing<SUI>(1000, s.ctx());
        let (ticket, mut req) = group::request_join(&g, s.ctx());
        simple_payment_rule::pay(&set, &fee_config, 1000, &mut req, &mut payment, s.ctx());
        group::execute_join(&mut g, &set, ticket, req, &clock);
        assert!(group::is_member(&g, ALICE));
        payment.destroy_zero();
        ts::return_shared(g);
        ts::return_shared(fee_config);
        ts::return_shared(set);
    };

    // Bob shows a holding; he never pays.
    s.next_tx(BOB);
    {
        let mut g = s.take_shared<Group>();
        let set = s.take_shared<RuleSet<JoinGroupOp>>();
        let holdings = coin::mint_for_testing<SUI>(500, s.ctx());
        let (ticket, mut req) = group::request_join(&g, s.ctx());
        token_gated_rule::prove(&set, &mut req, &holdings);
        group::execute_join(&mut g, &set, ticket, req, &clock);
        assert!(group::is_member(&g, BOB));
        assert!(group::member_count(&g) == 2);
        holdings.burn_for_testing();
        ts::return_shared(g);
        ts::return_shared(set);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = 3, location = humming::rules)]
fun group_any_of_none_satisfied_aborts() {
    let mut s = ts::begin(ADMIN);
    setup_any_of_group(&mut s);
    let clock = new_clock(&mut s);

    // Carol satisfies neither any-of rule.
    s.next_tx(CAROL);
    let mut g = s.take_shared<Group>();
    let set = s.take_shared<RuleSet<JoinGroupOp>>();
    let (ticket, req) = group::request_join(&g, s.ctx());
    group::execute_join(&mut g, &set, ticket, req, &clock);
    ts::return_shared(g);
    ts::return_shared(set);
    clock.destroy_for_testing();
    s.end();
}

/// A required rule's stamp must not count toward the any-of quota.
#[test]
#[expected_failure(abort_code = 3, location = humming::rules)]
fun group_required_stamp_does_not_count_as_any_of() {
    let mut s = ts::begin(ADMIN);
    setup_group(&mut s);
    let clock = new_clock(&mut s);

    // token rule REQUIRED, payment rule ANY-OF.
    s.next_tx(ADMIN);
    {
        let mut set = s.take_shared<RuleSet<JoinGroupOp>>();
        let cap = s.take_from_sender<RuleSetCap>();
        token_gated_rule::add<JoinGroupOp, SUI>(&mut set, &cap, 500, true);
        simple_payment_rule::add<JoinGroupOp, SUI>(&mut set, &cap, 1000, ADMIN, false);
        s.return_to_sender(cap);
        ts::return_shared(set);
    };

    // Alice proves the required token rule but never pays.
    s.next_tx(ALICE);
    let mut g = s.take_shared<Group>();
    let set = s.take_shared<RuleSet<JoinGroupOp>>();
    let holdings = coin::mint_for_testing<SUI>(600, s.ctx());
    let (ticket, mut req) = group::request_join(&g, s.ctx());
    token_gated_rule::prove(&set, &mut req, &holdings);
    group::execute_join(&mut g, &set, ticket, req, &clock);
    holdings.burn_for_testing();
    ts::return_shared(g);
    ts::return_shared(set);
    clock.destroy_for_testing();
    s.end();
}

/// The mirror image: an any-of stamp must not satisfy a required rule.
#[test]
#[expected_failure(abort_code = 2, location = humming::rules)]
fun group_any_of_stamp_does_not_count_as_required() {
    let mut s = ts::begin(ADMIN);
    setup_group(&mut s);
    setup_platform(&mut s);
    let clock = new_clock(&mut s);

    s.next_tx(ADMIN);
    {
        let mut set = s.take_shared<RuleSet<JoinGroupOp>>();
        let cap = s.take_from_sender<RuleSetCap>();
        token_gated_rule::add<JoinGroupOp, SUI>(&mut set, &cap, 500, true);
        simple_payment_rule::add<JoinGroupOp, SUI>(&mut set, &cap, 1000, ADMIN, false);
        s.return_to_sender(cap);
        ts::return_shared(set);
    };

    // Alice pays (any-of) but never proves the required token rule.
    s.next_tx(ALICE);
    let mut g = s.take_shared<Group>();
    let fee_config = s.take_shared<FeeConfig>();
    let set = s.take_shared<RuleSet<JoinGroupOp>>();
    let mut payment = coin::mint_for_testing<SUI>(1000, s.ctx());
    let (ticket, mut req) = group::request_join(&g, s.ctx());
    simple_payment_rule::pay(&set, &fee_config, 1000, &mut req, &mut payment, s.ctx());
    group::execute_join(&mut g, &set, ticket, req, &clock);
    payment.destroy_zero();
    ts::return_shared(g);
    ts::return_shared(fee_config);
    ts::return_shared(set);
    clock.destroy_for_testing();
    s.end();
}

/// The generic witness makes each coin type its own rule identity:
/// "hold coin X OR coin Y" as two any-of entries in one set.
#[test]
fun token_gated_two_coin_types_any_of() {
    let mut s = ts::begin(ADMIN);
    setup_group(&mut s);
    let clock = new_clock(&mut s);

    s.next_tx(ADMIN);
    {
        let mut set = s.take_shared<RuleSet<JoinGroupOp>>();
        let cap = s.take_from_sender<RuleSetCap>();
        token_gated_rule::add<JoinGroupOp, SUI>(&mut set, &cap, 500, false);
        token_gated_rule::add<JoinGroupOp, USDX>(&mut set, &cap, 300, false);
        s.return_to_sender(cap);
        ts::return_shared(set);
    };

    // Alice holds only USDX; that alone admits her.
    s.next_tx(ALICE);
    {
        let mut g = s.take_shared<Group>();
        let set = s.take_shared<RuleSet<JoinGroupOp>>();
        let holdings = coin::mint_for_testing<USDX>(300, s.ctx());
        let (ticket, mut req) = group::request_join(&g, s.ctx());
        token_gated_rule::prove(&set, &mut req, &holdings);
        group::execute_join(&mut g, &set, ticket, req, &clock);
        assert!(group::is_member(&g, ALICE));
        holdings.burn_for_testing();
        ts::return_shared(g);
        ts::return_shared(set);
    };

    clock.destroy_for_testing();
    s.end();
}

// === Failure-path completion ===

/// Double-banning is a caller bug and aborts with a domain error, not
/// a raw table abort.
#[test]
#[expected_failure(abort_code = 10, location = humming::group)]
fun group_double_ban_aborts() {
    let mut s = ts::begin(ADMIN);
    setup_group(&mut s);

    s.next_tx(ADMIN);
    let mut g = s.take_shared<Group>();
    let admin_cap = s.take_from_sender<group::GroupAdminCap>();
    group::ban(&mut g, &admin_cap, BOB);
    group::ban(&mut g, &admin_cap, BOB);
    s.return_to_sender(admin_cap);
    ts::return_shared(g);
    s.end();
}

#[test]
#[expected_failure(abort_code = 1, location = humming::group)]
fun group_leave_not_member_aborts() {
    let mut s = ts::begin(ADMIN);
    setup_group(&mut s);

    s.next_tx(ALICE);
    let mut g = s.take_shared<Group>();
    group::leave(&mut g, s.ctx());
    ts::return_shared(g);
    s.end();
}

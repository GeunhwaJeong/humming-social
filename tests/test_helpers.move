// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Shared fixtures for the per-module test files: persona addresses,
/// primitive setup helpers, and test-only types. Persona constants are
/// re-declared in each test file (Move constants are module-private);
/// the values here are the single source of truth.
#[test_only]
module humming::test_helpers;

use humming::creator_prefs;
use humming::feed::{Self, CreatePostOp, Feed};
use humming::graph::{Self, FollowOp, Graph};
use humming::group;
use humming::humming::init_for_testing;
use humming::locked_token_rule;
use humming::namespace;
use humming::platform::{Self, FeeConfig, FeeConfigCap};
use humming::rules::{RuleSet, RuleSetCap};
use humming::simple_payment_rule;
use humming::token_gated_rule;
use humming::username_validation_rule;
use humming::namespace::CreateUsernameOp;
use humming::group::JoinGroupOp;
use std::string::{Self, String};
use sui::clock::{Self, Clock};
use sui::sui::SUI;
use sui::test_scenario::{Self as ts, Scenario};

const ADMIN: address = @0xAD;

const DAY_MS: u64 = 86_400_000;

public fun str(bytes: vector<u8>): String { string::utf8(bytes) }

/// Test-only rule witness: each phantom instantiation has a distinct
/// `TypeName`, giving an unbounded supply of rule identities for
/// exercising `MAX_RULES`.
public struct FillerRule<phantom T> has drop {}

public fun filler_rule<T>(): FillerRule<T> { FillerRule<T> {} }

/// Test-only second coin type, for multi-currency gate tests.
public struct USDX has drop {}

public fun new_clock(s: &mut Scenario): Clock {
    clock::create_for_testing(s.ctx())
}

/// Runs the package initializer, creating (among the rest) the
/// canonical `FeeConfig` with ADMIN as treasury, then sets the fee to 5%
/// (exactly `MAX_FEE_BPS`) so the money tests exercise a non-trivial
/// split at the ceiling boundary. The initializer
/// itself launches at 0% (see `humming::humming`); `init_tests` covers
/// that default.
public fun setup_platform(s: &mut Scenario) {
    s.next_tx(ADMIN);
    init_for_testing(s.ctx());
    s.next_tx(ADMIN);
    let mut fee_config = s.take_shared<FeeConfig>();
    let cap = s.take_from_sender<FeeConfigCap>();
    platform::set_fee_bps(&mut fee_config, &cap, 500);
    s.return_to_sender(cap);
    ts::return_shared(fee_config);
}

public fun setup_namespace(s: &mut Scenario) {
    s.next_tx(ADMIN);
    let (admin_cap, rules_cap) = namespace::create(str(b"lens"), str(b""), s.ctx());
    transfer::public_transfer(admin_cap, ADMIN);
    transfer::public_transfer(rules_cap, ADMIN);
    // Admin wires in the username validation rule (3..=20 chars).
    s.next_tx(ADMIN);
    let mut set = s.take_shared<RuleSet<CreateUsernameOp>>();
    let cap = s.take_from_sender<RuleSetCap>();
    username_validation_rule::add(&mut set, &cap, 3, 20, true);
    s.return_to_sender(cap);
    ts::return_shared(set);
}

public fun setup_graph(s: &mut Scenario) {
    s.next_tx(ADMIN);
    let (admin_cap, rules_cap) = graph::create(str(b""), s.ctx());
    transfer::public_transfer(admin_cap, ADMIN);
    transfer::public_transfer(rules_cap, ADMIN);
}

/// Follow with no per-account rules configured on the target.
public fun follow(s: &mut Scenario, follower: address, target: address, clock: &Clock) {
    s.next_tx(follower);
    let mut g = s.take_shared<Graph>();
    let set = ts::take_shared_by_id<RuleSet<FollowOp>>(s, graph::graph_rules_id(&g));
    let (ticket, req) = graph::request_follow(&g, target, s.ctx());
    graph::execute_follow(&mut g, &set, ticket, req, clock, s.ctx());
    ts::return_shared(g);
    ts::return_shared(set);
}

/// Registers a payment-gated follow rule set for `account`.
public fun setup_paid_follow(s: &mut Scenario, account: address, amount: u64) {
    s.next_tx(account);
    {
        let mut g = s.take_shared<Graph>();
        let rules_cap = graph::create_my_follow_rules(&mut g, s.ctx());
        transfer::public_transfer(rules_cap, account);
        ts::return_shared(g);
    };
    s.next_tx(account);
    {
        let g = s.take_shared<Graph>();
        let set_id = graph::follow_rules_of(&g, account).destroy_some();
        let mut set = ts::take_shared_by_id<RuleSet<FollowOp>>(s, set_id);
        let cap = s.take_from_sender<RuleSetCap>();
        simple_payment_rule::add<FollowOp, SUI>(&mut set, &cap, amount, account, true);
        s.return_to_sender(cap);
        ts::return_shared(set);
        ts::return_shared(g);
    };
}

public fun setup_feed(s: &mut Scenario) {
    s.next_tx(ADMIN);
    let (admin_cap, rules_cap) = feed::create(str(b""), s.ctx());
    transfer::public_transfer(admin_cap, ADMIN);
    transfer::public_transfer(rules_cap, ADMIN);
}

public fun create_simple_post(
    s: &mut Scenario,
    author: address,
    content: vector<u8>,
    clock: &Clock,
): u64 {
    s.next_tx(author);
    let mut f = s.take_shared<Feed>();
    let set = ts::take_shared_by_id<RuleSet<CreatePostOp>>(s, feed::feed_rules_id(&f));
    let (ticket, req) = feed::request_create_post(
        &f,
        str(content),
        option::none(),
        option::none(),
        option::none(),
        s.ctx(),
    );
    let post_id = feed::execute_create_post(&mut f, &set, ticket, req, clock);
    ts::return_shared(f);
    ts::return_shared(set);
    post_id
}

public fun setup_group(s: &mut Scenario) {
    s.next_tx(ADMIN);
    let (admin_cap, rules_cap) = group::create(str(b""), s.ctx());
    transfer::public_transfer(admin_cap, ADMIN);
    transfer::public_transfer(rules_cap, ADMIN);
}

/// Group whose join rule set has two ANY-OF rules: hold at least 500
/// GEUNHWA, or pay 1000. Satisfying either one admits.
public fun setup_any_of_group(s: &mut Scenario) {
    setup_group(s);
    s.next_tx(ADMIN);
    let mut set = s.take_shared<RuleSet<JoinGroupOp>>();
    let cap = s.take_from_sender<RuleSetCap>();
    token_gated_rule::add<JoinGroupOp, SUI>(&mut set, &cap, 500, false);
    simple_payment_rule::add<JoinGroupOp, SUI>(&mut set, &cap, 1000, ADMIN, false);
    s.return_to_sender(cap);
    ts::return_shared(set);
}

/// Group whose join rule requires 500 GEUNHWA locked for a day.
public fun setup_locked_group(s: &mut Scenario) {
    setup_group(s);
    s.next_tx(ADMIN);
    let mut set = s.take_shared<RuleSet<JoinGroupOp>>();
    let cap = s.take_from_sender<RuleSetCap>();
    locked_token_rule::add<JoinGroupOp, SUI>(&mut set, &cap, 500, DAY_MS, true);
    s.return_to_sender(cap);
    ts::return_shared(set);
}

public fun setup_creator_prefs(s: &mut Scenario) {
    s.next_tx(ADMIN);
    creator_prefs::init_for_testing(s.ctx());
}

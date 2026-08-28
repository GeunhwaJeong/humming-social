// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Tests for `humming::graph`: following, per-account follow rules,
/// and the adversarial paths of the rule system as exercised through
/// paid follows.
#[test_only]
module humming::graph_tests;

use humming::graph::{Self, FollowOp, Graph};
use humming::platform::FeeConfig;
use humming::rules::{RuleSet, RuleSetCap};
use humming::simple_payment_rule;
use humming::test_helpers::{new_clock, setup_platform, setup_graph, setup_paid_follow, follow};
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::test_scenario::{Self as ts};

const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;
const CAROL: address = @0xCA401;

#[test]
fun graph_follow_unfollow() {
    let mut s = ts::begin(ADMIN);
    setup_graph(&mut s);
    let clock = new_clock(&mut s);

    follow(&mut s, ALICE, BOB, &clock);
    follow(&mut s, CAROL, BOB, &clock);

    s.next_tx(ALICE);
    {
        let g = s.take_shared<Graph>();
        assert!(graph::is_following(&g, ALICE, BOB));
        assert!(!graph::is_following(&g, BOB, ALICE));
        assert!(graph::followers_count_of(&g, BOB) == 2);
        assert!(graph::following_count_of(&g, ALICE) == 1);
        ts::return_shared(g);
    };

    s.next_tx(ALICE);
    {
        let mut g = s.take_shared<Graph>();
        graph::unfollow(&mut g, BOB, s.ctx());
        assert!(!graph::is_following(&g, ALICE, BOB));
        assert!(graph::followers_count_of(&g, BOB) == 1);
        ts::return_shared(g);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
fun graph_paid_follow() {
    let mut s = ts::begin(ADMIN);
    setup_graph(&mut s);
    setup_platform(&mut s);
    let clock = new_clock(&mut s);

    // Bob gates follows on himself: 1000 GEUNHWA to follow.
    setup_paid_follow(&mut s, BOB, 1000);

    // Alice pays and follows.
    s.next_tx(ALICE);
    {
        let mut g = s.take_shared<Graph>();
        let fee_config = s.take_shared<FeeConfig>();
        let graph_set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, graph::graph_rules_id(&g));
        let bob_set_id = graph::follow_rules_of(&g, BOB).destroy_some();
        let bob_set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, bob_set_id);
        // Pays with a larger coin: the amount is split off, change stays.
        let mut payment = coin::mint_for_testing<SUI>(1500, s.ctx());
        let (ticket, mut req) = graph::request_follow(&g, BOB, s.ctx());
        simple_payment_rule::pay(&bob_set, &fee_config, 1000, &mut req, &mut payment, s.ctx());
        assert!(payment.value() == 500);
        graph::execute_follow_gated(&mut g, &graph_set, &bob_set, ticket, req, &clock, s.ctx());
        assert!(graph::is_following(&g, ALICE, BOB));
        payment.burn_for_testing();
        ts::return_shared(g);
        ts::return_shared(fee_config);
        ts::return_shared(graph_set);
        ts::return_shared(bob_set);
    };

    // Bob received the payment minus the 5% platform cut.
    s.next_tx(BOB);
    {
        let payment = s.take_from_sender<Coin<SUI>>();
        assert!(payment.value() == 950);
        s.return_to_sender(payment);
    };

    // The treasury (ADMIN) received the cut.
    s.next_tx(ADMIN);
    {
        let cut = s.take_from_sender<Coin<SUI>>();
        assert!(cut.value() == 50);
        s.return_to_sender(cut);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = 2, location = humming::platform)]
fun graph_paid_follow_wrong_amount() {
    let mut s = ts::begin(ADMIN);
    setup_graph(&mut s);
    setup_platform(&mut s);
    let clock = new_clock(&mut s);
    setup_paid_follow(&mut s, BOB, 1000);

    // Underpaying must abort.
    s.next_tx(ALICE);
    let mut g = s.take_shared<Graph>();
    let fee_config = s.take_shared<FeeConfig>();
    let graph_set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, graph::graph_rules_id(&g));
    let bob_set_id = graph::follow_rules_of(&g, BOB).destroy_some();
    let bob_set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, bob_set_id);
    let mut payment = coin::mint_for_testing<SUI>(999, s.ctx());
    let (ticket, mut req) = graph::request_follow(&g, BOB, s.ctx());
    simple_payment_rule::pay(&bob_set, &fee_config, 1000, &mut req, &mut payment, s.ctx());
    graph::execute_follow_gated(&mut g, &graph_set, &bob_set, ticket, req, &clock, s.ctx());
    payment.burn_for_testing();
    ts::return_shared(g);
    ts::return_shared(fee_config);
    ts::return_shared(graph_set);
    ts::return_shared(bob_set);
    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = 6, location = humming::graph)]
fun graph_cannot_skip_target_rules() {
    let mut s = ts::begin(ADMIN);
    setup_graph(&mut s);
    let clock = new_clock(&mut s);

    s.next_tx(BOB);
    {
        let mut g = s.take_shared<Graph>();
        let rules_cap = graph::create_my_follow_rules(&mut g, s.ctx());
        transfer::public_transfer(rules_cap, BOB);
        ts::return_shared(g);
    };

    // Using the non-gated path against a rule-gated target must abort.
    s.next_tx(ALICE);
    let mut g = s.take_shared<Graph>();
    let graph_set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, graph::graph_rules_id(&g));
    let (ticket, req) = graph::request_follow(&g, BOB, s.ctx());
    graph::execute_follow(&mut g, &graph_set, ticket, req, &clock, s.ctx());
    ts::return_shared(g);
    ts::return_shared(graph_set);
    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = 1, location = humming::simple_payment_rule)]
fun graph_double_pay_aborts() {
    let mut s = ts::begin(ADMIN);
    setup_graph(&mut s);
    setup_platform(&mut s);
    let clock = new_clock(&mut s);
    setup_paid_follow(&mut s, BOB, 1000);

    // Paying the same rule set twice for one request must abort, not
    // silently take a second payment.
    s.next_tx(ALICE);
    let mut g = s.take_shared<Graph>();
    let fee_config = s.take_shared<FeeConfig>();
    let graph_set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, graph::graph_rules_id(&g));
    let bob_set_id = graph::follow_rules_of(&g, BOB).destroy_some();
    let bob_set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, bob_set_id);
    let mut payment = coin::mint_for_testing<SUI>(3000, s.ctx());
    let (ticket, mut req) = graph::request_follow(&g, BOB, s.ctx());
    simple_payment_rule::pay(&bob_set, &fee_config, 1000, &mut req, &mut payment, s.ctx());
    simple_payment_rule::pay(&bob_set, &fee_config, 1000, &mut req, &mut payment, s.ctx());
    graph::execute_follow_gated(&mut g, &graph_set, &bob_set, ticket, req, &clock, s.ctx());
    payment.burn_for_testing();
    ts::return_shared(g);
    ts::return_shared(fee_config);
    ts::return_shared(graph_set);
    ts::return_shared(bob_set);
    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = 2, location = humming::rules)]
fun graph_stamp_cannot_replay_across_rule_sets() {
    let mut s = ts::begin(ADMIN);
    setup_graph(&mut s);
    setup_platform(&mut s);
    let clock = new_clock(&mut s);
    // Carol charges 10, Bob charges 1000.
    setup_paid_follow(&mut s, CAROL, 10);
    setup_paid_follow(&mut s, BOB, 1000);

    // Alice pays Carol's cheap fee, then tries to use that stamp to
    // follow Bob. The stamp is bound to Carol's rule set ID, so Bob's
    // required payment rule reads as unsatisfied.
    s.next_tx(ALICE);
    let mut g = s.take_shared<Graph>();
    let fee_config = s.take_shared<FeeConfig>();
    let graph_set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, graph::graph_rules_id(&g));
    let carol_set_id = graph::follow_rules_of(&g, CAROL).destroy_some();
    let carol_set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, carol_set_id);
    let bob_set_id = graph::follow_rules_of(&g, BOB).destroy_some();
    let bob_set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, bob_set_id);
    let mut payment = coin::mint_for_testing<SUI>(10, s.ctx());
    let (ticket, mut req) = graph::request_follow(&g, BOB, s.ctx());
    simple_payment_rule::pay(&carol_set, &fee_config, 10, &mut req, &mut payment, s.ctx());
    graph::execute_follow_gated(&mut g, &graph_set, &bob_set, ticket, req, &clock, s.ctx());
    payment.burn_for_testing();
    ts::return_shared(g);
    ts::return_shared(fee_config);
    ts::return_shared(graph_set);
    ts::return_shared(carol_set);
    ts::return_shared(bob_set);
    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = 4, location = humming::graph)]
fun graph_cannot_pass_foreign_rule_set() {
    let mut s = ts::begin(ADMIN);
    setup_graph(&mut s);
    let clock = new_clock(&mut s);
    setup_paid_follow(&mut s, BOB, 1000);

    // Alice registers her own (empty, always-passing) follow rule set...
    s.next_tx(ALICE);
    {
        let mut g = s.take_shared<Graph>();
        let rules_cap = graph::create_my_follow_rules(&mut g, s.ctx());
        transfer::public_transfer(rules_cap, ALICE);
        ts::return_shared(g);
    };

    // ...and tries to present it as Bob's when following him.
    s.next_tx(ALICE);
    let mut g = s.take_shared<Graph>();
    let graph_set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, graph::graph_rules_id(&g));
    let alice_set_id = graph::follow_rules_of(&g, ALICE).destroy_some();
    let alice_set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, alice_set_id);
    let (ticket, req) = graph::request_follow(&g, BOB, s.ctx());
    graph::execute_follow_gated(&mut g, &graph_set, &alice_set, ticket, req, &clock, s.ctx());
    ts::return_shared(g);
    ts::return_shared(graph_set);
    ts::return_shared(alice_set);
    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = 5, location = humming::graph)]
fun graph_key_mismatch_rejected() {
    let mut s = ts::begin(ADMIN);
    setup_graph(&mut s);
    let clock = new_clock(&mut s);

    // Pairing ticket A with request B must abort on the key check.
    s.next_tx(ALICE);
    let mut g = s.take_shared<Graph>();
    let graph_set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, graph::graph_rules_id(&g));
    let (ticket_bob, req_bob) = graph::request_follow(&g, BOB, s.ctx());
    let (ticket_carol, req_carol) = graph::request_follow(&g, CAROL, s.ctx());
    graph::execute_follow(&mut g, &graph_set, ticket_bob, req_carol, &clock, s.ctx());
    // Unreachable cleanup (the call above aborts).
    graph::execute_follow(&mut g, &graph_set, ticket_carol, req_bob, &clock, s.ctx());
    ts::return_shared(g);
    ts::return_shared(graph_set);
    clock.destroy_for_testing();
    s.end();
}

#[test]
fun graph_removed_rule_no_longer_enforced() {
    let mut s = ts::begin(ADMIN);
    setup_graph(&mut s);
    let clock = new_clock(&mut s);
    setup_paid_follow(&mut s, BOB, 1000);

    // Bob removes his payment rule; the registered set is now empty.
    s.next_tx(BOB);
    {
        let g = s.take_shared<Graph>();
        let set_id = graph::follow_rules_of(&g, BOB).destroy_some();
        let mut set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, set_id);
        let cap = s.take_from_sender<RuleSetCap>();
        simple_payment_rule::remove<FollowOp, SUI>(&mut set, &cap);
        s.return_to_sender(cap);
        ts::return_shared(set);
        ts::return_shared(g);
    };

    // Alice can now follow through the gated path without paying.
    s.next_tx(ALICE);
    {
        let mut g = s.take_shared<Graph>();
        let graph_set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, graph::graph_rules_id(&g));
        let bob_set_id = graph::follow_rules_of(&g, BOB).destroy_some();
        let bob_set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, bob_set_id);
        let (ticket, req) = graph::request_follow(&g, BOB, s.ctx());
        graph::execute_follow_gated(&mut g, &graph_set, &bob_set, ticket, req, &clock, s.ctx());
        assert!(graph::is_following(&g, ALICE, BOB));
        ts::return_shared(g);
        ts::return_shared(graph_set);
        ts::return_shared(bob_set);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = 2, location = humming::simple_payment_rule)]
fun pay_amount_mismatch_aborts() {
    let mut s = ts::begin(ADMIN);
    setup_graph(&mut s);
    setup_platform(&mut s);
    let clock = new_clock(&mut s);
    setup_paid_follow(&mut s, BOB, 1000);

    // Bob re-configures his follow fee to 5000.
    s.next_tx(BOB);
    {
        let g = s.take_shared<Graph>();
        let set_id = graph::follow_rules_of(&g, BOB).destroy_some();
        let mut set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, set_id);
        let cap = s.take_from_sender<RuleSetCap>();
        simple_payment_rule::remove<FollowOp, SUI>(&mut set, &cap);
        simple_payment_rule::add<FollowOp, SUI>(&mut set, &cap, 5000, BOB, true);
        s.return_to_sender(cap);
        ts::return_shared(set);
        ts::return_shared(g);
    };

    // Alice still expects the 1000 fee she saw.
    s.next_tx(ALICE);
    let mut g = s.take_shared<Graph>();
    let fee_config = s.take_shared<FeeConfig>();
    let graph_set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, graph::graph_rules_id(&g));
    let bob_set_id = graph::follow_rules_of(&g, BOB).destroy_some();
    let bob_set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, bob_set_id);
    let mut payment = coin::mint_for_testing<SUI>(5000, s.ctx());
    let (ticket, mut req) = graph::request_follow(&g, BOB, s.ctx());
    simple_payment_rule::pay(&bob_set, &fee_config, 1000, &mut req, &mut payment, s.ctx());
    graph::execute_follow_gated(&mut g, &graph_set, &bob_set, ticket, req, &clock, s.ctx());
    payment.burn_for_testing();
    ts::return_shared(g);
    ts::return_shared(fee_config);
    ts::return_shared(graph_set);
    ts::return_shared(bob_set);
    clock.destroy_for_testing();
    s.end();
}

// === Failure-path completion ===

#[test]
#[expected_failure(abort_code = 0, location = humming::graph)]
fun graph_cannot_follow_self() {
    let mut s = ts::begin(ADMIN);
    setup_graph(&mut s);
    let clock = new_clock(&mut s);

    s.next_tx(ALICE);
    let mut g = s.take_shared<Graph>();
    let graph_set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, graph::graph_rules_id(&g));
    // Aborts here; the execute call below is unreachable cleanup that
    // consumes the hot potatoes for the static analysis.
    let (ticket, req) = graph::request_follow(&g, ALICE, s.ctx());
    graph::execute_follow(&mut g, &graph_set, ticket, req, &clock, s.ctx());
    ts::return_shared(g);
    ts::return_shared(graph_set);
    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = 2, location = humming::graph)]
fun graph_unfollow_not_following_aborts() {
    let mut s = ts::begin(ADMIN);
    setup_graph(&mut s);

    s.next_tx(ALICE);
    let mut g = s.take_shared<Graph>();
    graph::unfollow(&mut g, BOB, s.ctx());
    ts::return_shared(g);
    s.end();
}

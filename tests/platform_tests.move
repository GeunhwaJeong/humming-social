// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Tests for `humming::platform`: the fee lever, the payment circuit
/// breaker, and the three-step `FeeConfigCap` handoff.
#[test_only]
module humming::platform_tests;

use humming::feed::Feed;
use humming::graph::{Self, FollowOp, Graph};
use humming::humming::init_for_testing;
use humming::paid_posts::{Self, PostPaywall};
use humming::platform::{Self, FeeConfig, FeeConfigCap};
use humming::rules::RuleSet;
use humming::simple_payment_rule;
use humming::subscriptions::{Self, Tier};
use humming::test_helpers::{
    str,
    new_clock,
    setup_platform,
    setup_graph,
    setup_paid_follow,
    setup_feed,
    create_simple_post,
};
use humming::tips;
use sui::coin::{Self, Coin};
use sui::event;
use sui::sui::SUI;
use sui::test_scenario::{Self as ts, Scenario};

const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;
const CAROL: address = @0xCA401;

const DAY_MS: u64 = 86_400_000;

// === Fee lever ===

/// The fee lever: governance (here: the cap holder) walks the fee to
/// zero and creators start receiving 100%.
#[test]
fun fee_can_be_walked_to_zero() {
    let mut s = ts::begin(ADMIN);
    setup_platform(&mut s);
    let clock = new_clock(&mut s);

    s.next_tx(ADMIN);
    {
        let mut fee_config = s.take_shared<FeeConfig>();
        let cap = s.take_from_sender<FeeConfigCap>();
        platform::set_fee_bps(&mut fee_config, &cap, 0);
        assert!(platform::fee_bps(&fee_config) == 0);
        assert!(platform::compute_fee(&fee_config, 1000) == 0);
        s.return_to_sender(cap);
        ts::return_shared(fee_config);
    };

    s.next_tx(BOB);
    {
        let cap = subscriptions::create<SUI>(1000, DAY_MS, str(b""), s.ctx());
        transfer::public_transfer(cap, BOB);
    };
    s.next_tx(ALICE);
    {
        let mut tier = s.take_shared<Tier<SUI>>();
        let fee_config = s.take_shared<FeeConfig>();
        let mut payment = coin::mint_for_testing<SUI>(1000, s.ctx());
        subscriptions::subscribe(&mut tier, &fee_config, ALICE, 1000, &mut payment, &clock, s.ctx());
        payment.destroy_zero();
        ts::return_shared(tier);
        ts::return_shared(fee_config);
    };

    // Bob receives the full amount.
    s.next_tx(BOB);
    {
        let proceeds = s.take_from_sender<Coin<SUI>>();
        assert!(proceeds.value() == 1000);
        s.return_to_sender(proceeds);
    };

    clock.destroy_for_testing();
    s.end();
}

/// No cap holder — platform or governance — can push the fee past the
/// compile-time ceiling.
#[test]
#[expected_failure(abort_code = 0, location = humming::platform)]
fun fee_above_ceiling_rejected() {
    let mut s = ts::begin(ADMIN);
    setup_platform(&mut s);

    s.next_tx(ADMIN);
    let mut fee_config = s.take_shared<FeeConfig>();
    let cap = s.take_from_sender<FeeConfigCap>();
    platform::set_fee_bps(&mut fee_config, &cap, platform::max_fee_bps() + 1);
    s.return_to_sender(cap);
    ts::return_shared(fee_config);
    s.end();
}

/// The ceiling itself is a legal value: `<=`, not `<`. Pins the boundary
/// so a future tweak of the comparison cannot silently shrink the range.
#[test]
fun fee_at_ceiling_accepted() {
    let mut s = ts::begin(ADMIN);
    setup_platform(&mut s);

    s.next_tx(ADMIN);
    let mut fee_config = s.take_shared<FeeConfig>();
    let cap = s.take_from_sender<FeeConfigCap>();
    platform::set_fee_bps(&mut fee_config, &cap, platform::max_fee_bps());
    assert!(platform::fee_bps(&fee_config) == platform::max_fee_bps());
    // 5% of 10_000 units is 500 at the ceiling.
    assert!(platform::compute_fee(&fee_config, 10_000) == 500);
    s.return_to_sender(cap);
    ts::return_shared(fee_config);
    s.end();
}

// === Circuit breaker ===

fun pause(s: &mut Scenario) {
    s.next_tx(ADMIN);
    let mut fee_config = s.take_shared<FeeConfig>();
    let cap = s.take_from_sender<FeeConfigCap>();
    platform::set_paused(&mut fee_config, &cap, true);
    assert!(platform::is_paused(&fee_config));
    assert!(event::events_by_type<platform::PauseChanged>().length() == 1);
    s.return_to_sender(cap);
    ts::return_shared(fee_config);
}

#[test]
#[expected_failure(abort_code = 5, location = humming::platform)]
fun pause_blocks_subscribe() {
    let mut s = ts::begin(ADMIN);
    setup_platform(&mut s);
    let clock = new_clock(&mut s);

    s.next_tx(BOB);
    {
        let cap = subscriptions::create<SUI>(1000, DAY_MS, str(b""), s.ctx());
        transfer::public_transfer(cap, BOB);
    };
    pause(&mut s);

    s.next_tx(ALICE);
    let mut tier = s.take_shared<Tier<SUI>>();
    let fee_config = s.take_shared<FeeConfig>();
    let mut payment = coin::mint_for_testing<SUI>(1000, s.ctx());
    subscriptions::subscribe(&mut tier, &fee_config, ALICE, 1000, &mut payment, &clock, s.ctx());
    payment.destroy_zero();
    ts::return_shared(tier);
    ts::return_shared(fee_config);
    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = 5, location = humming::platform)]
fun pause_blocks_purchase() {
    let mut s = ts::begin(ADMIN);
    setup_feed(&mut s);
    setup_platform(&mut s);
    let clock = new_clock(&mut s);

    let p1 = create_simple_post(&mut s, ALICE, b"ipfs://premium", &clock);
    s.next_tx(ALICE);
    {
        let mut f = s.take_shared<Feed>();
        paid_posts::create<SUI>(&mut f, p1, 500, s.ctx());
        ts::return_shared(f);
    };
    pause(&mut s);

    s.next_tx(BOB);
    let mut paywall = s.take_shared<PostPaywall<SUI>>();
    let fee_config = s.take_shared<FeeConfig>();
    let f = s.take_shared<Feed>();
    let mut payment = coin::mint_for_testing<SUI>(500, s.ctx());
    paid_posts::purchase(&mut paywall, &fee_config, &f, 500, &mut payment, s.ctx());
    payment.burn_for_testing();
    ts::return_shared(paywall);
    ts::return_shared(fee_config);
    ts::return_shared(f);
    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = 5, location = humming::platform)]
fun pause_blocks_tip() {
    let mut s = ts::begin(ADMIN);
    setup_platform(&mut s);
    pause(&mut s);

    s.next_tx(BOB);
    let fee_config = s.take_shared<FeeConfig>();
    let mut payment = coin::mint_for_testing<SUI>(100, s.ctx());
    tips::tip(&fee_config, ALICE, 100, &mut payment, s.ctx());
    payment.burn_for_testing();
    ts::return_shared(fee_config);
    s.end();
}

#[test]
#[expected_failure(abort_code = 5, location = humming::platform)]
fun pause_blocks_paid_follow() {
    let mut s = ts::begin(ADMIN);
    setup_graph(&mut s);
    setup_platform(&mut s);
    let clock = new_clock(&mut s);
    setup_paid_follow(&mut s, BOB, 1000);
    pause(&mut s);

    s.next_tx(ALICE);
    let mut g = s.take_shared<Graph>();
    let fee_config = s.take_shared<FeeConfig>();
    let graph_set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, graph::graph_rules_id(&g));
    let bob_set_id = graph::follow_rules_of(&g, BOB).destroy_some();
    let bob_set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, bob_set_id);
    let mut payment = coin::mint_for_testing<SUI>(1000, s.ctx());
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
fun unpause_restores_payments() {
    let mut s = ts::begin(ADMIN);
    setup_platform(&mut s);
    pause(&mut s);

    s.next_tx(ADMIN);
    {
        let mut fee_config = s.take_shared<FeeConfig>();
        let cap = s.take_from_sender<FeeConfigCap>();
        platform::set_paused(&mut fee_config, &cap, false);
        assert!(!platform::is_paused(&fee_config));
        s.return_to_sender(cap);
        ts::return_shared(fee_config);
    };

    // Payments flow again.
    s.next_tx(BOB);
    {
        let fee_config = s.take_shared<FeeConfig>();
        let mut payment = coin::mint_for_testing<SUI>(100, s.ctx());
        tips::tip(&fee_config, ALICE, 100, &mut payment, s.ctx());
        payment.destroy_zero();
        ts::return_shared(fee_config);
    };

    s.end();
}

/// A cap minted for a different config cannot pause this one. (The
/// second `init_for_testing` run stands in for a hypothetical foreign
/// deployment.)
#[test]
#[expected_failure(abort_code = 1, location = humming::platform)]
fun set_paused_foreign_cap_rejected() {
    let mut s = ts::begin(ADMIN);
    setup_platform(&mut s);

    // Capture the canonical config's id while it is the only one.
    s.next_tx(ADMIN);
    let config_id = {
        let fee_config = s.take_shared<FeeConfig>();
        let id = object::id(&fee_config);
        ts::return_shared(fee_config);
        id
    };

    // Bob "deploys" a second config and holds its cap.
    s.next_tx(BOB);
    init_for_testing(s.ctx());

    s.next_tx(BOB);
    let mut fee_config = ts::take_shared_by_id<FeeConfig>(&s, config_id);
    let bob_cap = s.take_from_sender<FeeConfigCap>();
    platform::set_paused(&mut fee_config, &bob_cap, true);
    s.return_to_sender(bob_cap);
    ts::return_shared(fee_config);
    s.end();
}

// === Cap handoff (propose → accept → execute) ===

fun propose(s: &mut Scenario, to: address) {
    s.next_tx(ADMIN);
    let mut fee_config = s.take_shared<FeeConfig>();
    let cap = s.take_from_sender<FeeConfigCap>();
    platform::propose_cap_transfer(&mut fee_config, &cap, to, s.ctx());
    s.return_to_sender(cap);
    ts::return_shared(fee_config);
}

fun accept(s: &mut Scenario, who: address) {
    s.next_tx(who);
    let mut fee_config = s.take_shared<FeeConfig>();
    platform::accept_cap_transfer(&mut fee_config, s.ctx());
    ts::return_shared(fee_config);
}

#[test]
fun cap_transfer_full_flow() {
    let mut s = ts::begin(ADMIN);
    setup_platform(&mut s);

    propose(&mut s, BOB);

    s.next_tx(BOB);
    {
        let fee_config = s.take_shared<FeeConfig>();
        assert!(platform::pending_cap_transfer_to(&fee_config) == option::some(BOB));
        assert!(platform::pending_cap_transfer_accepted(&fee_config) == option::some(false));
        ts::return_shared(fee_config);
    };
    accept(&mut s, BOB);

    s.next_tx(ADMIN);
    {
        let mut fee_config = s.take_shared<FeeConfig>();
        assert!(platform::pending_cap_transfer_accepted(&fee_config) == option::some(true));
        let cap = s.take_from_sender<FeeConfigCap>();
        platform::execute_cap_transfer(&mut fee_config, cap, s.ctx());
        assert!(platform::pending_cap_transfer_to(&fee_config).is_none());
        ts::return_shared(fee_config);
    };

    // Bob now holds the cap and can drive the levers.
    s.next_tx(BOB);
    {
        let mut fee_config = s.take_shared<FeeConfig>();
        let cap = s.take_from_sender<FeeConfigCap>();
        platform::set_fee_bps(&mut fee_config, &cap, 100);
        assert!(platform::fee_bps(&fee_config) == 100);
        s.return_to_sender(cap);
        ts::return_shared(fee_config);
    };

    s.end();
}

#[test]
#[expected_failure(abort_code = 8, location = humming::platform)]
fun cap_transfer_execute_without_accept_aborts() {
    let mut s = ts::begin(ADMIN);
    setup_platform(&mut s);
    propose(&mut s, BOB);

    s.next_tx(ADMIN);
    let mut fee_config = s.take_shared<FeeConfig>();
    let cap = s.take_from_sender<FeeConfigCap>();
    platform::execute_cap_transfer(&mut fee_config, cap, s.ctx());
    ts::return_shared(fee_config);
    s.end();
}

#[test]
#[expected_failure(abort_code = 7, location = humming::platform)]
fun cap_transfer_accept_by_stranger_aborts() {
    let mut s = ts::begin(ADMIN);
    setup_platform(&mut s);
    propose(&mut s, BOB);
    accept(&mut s, CAROL);
    s.end();
}

#[test]
#[expected_failure(abort_code = 6, location = humming::platform)]
fun cap_transfer_accept_without_proposal_aborts() {
    let mut s = ts::begin(ADMIN);
    setup_platform(&mut s);
    accept(&mut s, BOB);
    s.end();
}

#[test]
#[expected_failure(abort_code = 6, location = humming::platform)]
fun cap_transfer_execute_without_proposal_aborts() {
    let mut s = ts::begin(ADMIN);
    setup_platform(&mut s);

    s.next_tx(ADMIN);
    let mut fee_config = s.take_shared<FeeConfig>();
    let cap = s.take_from_sender<FeeConfigCap>();
    platform::execute_cap_transfer(&mut fee_config, cap, s.ctx());
    ts::return_shared(fee_config);
    s.end();
}

#[test]
#[expected_failure(abort_code = 9, location = humming::platform)]
fun cap_transfer_to_self_aborts() {
    let mut s = ts::begin(ADMIN);
    setup_platform(&mut s);
    propose(&mut s, ADMIN);
    s.end();
}

#[test]
#[expected_failure(abort_code = 6, location = humming::platform)]
fun cap_transfer_cancel_blocks_execute() {
    let mut s = ts::begin(ADMIN);
    setup_platform(&mut s);
    propose(&mut s, BOB);
    accept(&mut s, BOB);

    s.next_tx(ADMIN);
    {
        let mut fee_config = s.take_shared<FeeConfig>();
        let cap = s.take_from_sender<FeeConfigCap>();
        platform::cancel_cap_transfer(&mut fee_config, &cap);
        assert!(platform::pending_cap_transfer_to(&fee_config).is_none());
        s.return_to_sender(cap);
        ts::return_shared(fee_config);
    };

    s.next_tx(ADMIN);
    let mut fee_config = s.take_shared<FeeConfig>();
    let cap = s.take_from_sender<FeeConfigCap>();
    platform::execute_cap_transfer(&mut fee_config, cap, s.ctx());
    ts::return_shared(fee_config);
    s.end();
}

/// Re-proposing overwrites the pending transfer, so a stale acceptance
/// from the previous proposal cannot release the cap to the new target.
#[test]
#[expected_failure(abort_code = 8, location = humming::platform)]
fun cap_transfer_repropose_requires_fresh_accept() {
    let mut s = ts::begin(ADMIN);
    setup_platform(&mut s);
    propose(&mut s, BOB);
    accept(&mut s, BOB);
    propose(&mut s, CAROL);

    s.next_tx(ADMIN);
    let mut fee_config = s.take_shared<FeeConfig>();
    let cap = s.take_from_sender<FeeConfigCap>();
    platform::execute_cap_transfer(&mut fee_config, cap, s.ctx());
    ts::return_shared(fee_config);
    s.end();
}

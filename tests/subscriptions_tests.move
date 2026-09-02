// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Tests for `humming::subscriptions` and the `subscriber_only_rule`
/// bridge into the rule framework.
#[test_only]
module humming::subscriptions_tests;

use humming::feed::{Self, CreatePostOp, Feed, InteractPostOp};
use humming::group::{Self, Group, JoinGroupOp};
use humming::platform::FeeConfig;
use humming::rules::{RuleSet, RuleSetCap};
use humming::subscriber_only_rule;
use humming::subscriptions::{Self, Tier, TierCap};
use humming::test_helpers::{
    str,
    new_clock,
    setup_platform,
    setup_feed,
    setup_group,
    create_simple_post,
};
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::test_scenario::{Self as ts};

const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;
const CAROL: address = @0xCA401;

const DAY_MS: u64 = 86_400_000;

#[test]
fun subscription_lifecycle() {
    let mut s = ts::begin(ADMIN);
    setup_platform(&mut s);
    let mut clock = new_clock(&mut s);

    // Bob offers a tier: 1000 per day.
    s.next_tx(BOB);
    {
        let cap = subscriptions::create<SUI>(1000, DAY_MS, str(b"ipfs://tier"), s.ctx());
        transfer::public_transfer(cap, BOB);
    };

    // Alice subscribes, then immediately renews: periods stack.
    s.next_tx(ALICE);
    {
        let mut tier = s.take_shared<Tier<SUI>>();
        let fee_config = s.take_shared<FeeConfig>();
        let mut payment = coin::mint_for_testing<SUI>(2000, s.ctx());
        subscriptions::subscribe(&mut tier, &fee_config, ALICE, 1000, &mut payment, &clock, s.ctx());
        assert!(subscriptions::is_active_subscriber(&tier, ALICE, &clock));
        assert!(subscriptions::expires_ms(&tier, ALICE).destroy_some() == DAY_MS);
        subscriptions::subscribe(&mut tier, &fee_config, ALICE, 1000, &mut payment, &clock, s.ctx());
        assert!(subscriptions::expires_ms(&tier, ALICE).destroy_some() == 2 * DAY_MS);
        assert!(subscriptions::subscriber_count(&tier) == 1);
        payment.destroy_zero();
        ts::return_shared(tier);
        ts::return_shared(fee_config);
    };

    // Bob received 950 per period (5% platform cut).
    s.next_tx(BOB);
    {
        let c1 = s.take_from_sender<Coin<SUI>>();
        let c2 = s.take_from_sender<Coin<SUI>>();
        assert!(c1.value() + c2.value() == 1900);
        s.return_to_sender(c1);
        s.return_to_sender(c2);
    };

    // Past the prepaid time the subscription lapses by itself...
    s.next_tx(ALICE);
    {
        let mut tier = s.take_shared<Tier<SUI>>();
        let fee_config = s.take_shared<FeeConfig>();
        clock.set_for_testing(2 * DAY_MS + 1);
        assert!(!subscriptions::is_active_subscriber(&tier, ALICE, &clock));
        // ...and re-subscribing starts from now, not the stale expiry.
        let mut payment = coin::mint_for_testing<SUI>(1000, s.ctx());
        subscriptions::subscribe(&mut tier, &fee_config, ALICE, 1000, &mut payment, &clock, s.ctx());
        assert!(subscriptions::expires_ms(&tier, ALICE).destroy_some() == 3 * DAY_MS + 1);
        assert!(subscriptions::subscriber_count(&tier) == 1);
        payment.destroy_zero();
        ts::return_shared(tier);
        ts::return_shared(fee_config);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
fun subscription_gift() {
    let mut s = ts::begin(ADMIN);
    setup_platform(&mut s);
    let clock = new_clock(&mut s);

    s.next_tx(BOB);
    {
        let cap = subscriptions::create<SUI>(1000, DAY_MS, str(b""), s.ctx());
        transfer::public_transfer(cap, BOB);
    };

    // Alice pays; Carol gets the subscription.
    s.next_tx(ALICE);
    {
        let mut tier = s.take_shared<Tier<SUI>>();
        let fee_config = s.take_shared<FeeConfig>();
        let mut payment = coin::mint_for_testing<SUI>(1000, s.ctx());
        subscriptions::subscribe(&mut tier, &fee_config, CAROL, 1000, &mut payment, &clock, s.ctx());
        assert!(subscriptions::is_active_subscriber(&tier, CAROL, &clock));
        assert!(!subscriptions::is_active_subscriber(&tier, ALICE, &clock));
        payment.destroy_zero();
        ts::return_shared(tier);
        ts::return_shared(fee_config);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = 0, location = humming::subscriptions)]
fun subscription_closed_tier_rejects() {
    let mut s = ts::begin(ADMIN);
    setup_platform(&mut s);
    let clock = new_clock(&mut s);

    s.next_tx(BOB);
    {
        let cap = subscriptions::create<SUI>(1000, DAY_MS, str(b""), s.ctx());
        transfer::public_transfer(cap, BOB);
    };
    s.next_tx(BOB);
    {
        let mut tier = s.take_shared<Tier<SUI>>();
        let cap = s.take_from_sender<TierCap>();
        subscriptions::set_active(&mut tier, &cap, false);
        s.return_to_sender(cap);
        ts::return_shared(tier);
    };

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

/// Price guard: a subscription signed against the old price aborts
/// when the creator's price change lands first.
#[test]
#[expected_failure(abort_code = 5, location = humming::subscriptions)]
fun subscribe_price_mismatch_aborts() {
    let mut s = ts::begin(ADMIN);
    setup_platform(&mut s);
    let clock = new_clock(&mut s);

    s.next_tx(BOB);
    {
        let cap = subscriptions::create<SUI>(1000, DAY_MS, str(b""), s.ctx());
        transfer::public_transfer(cap, BOB);
    };
    // Bob raises the price to 2000 before Alice's purchase lands.
    s.next_tx(BOB);
    {
        let mut tier = s.take_shared<Tier<SUI>>();
        let cap = s.take_from_sender<TierCap>();
        subscriptions::set_price(&mut tier, &cap, 2000);
        s.return_to_sender(cap);
        ts::return_shared(tier);
    };

    // Alice still expects 1000.
    s.next_tx(ALICE);
    let mut tier = s.take_shared<Tier<SUI>>();
    let fee_config = s.take_shared<FeeConfig>();
    let mut payment = coin::mint_for_testing<SUI>(2000, s.ctx());
    subscriptions::subscribe(&mut tier, &fee_config, ALICE, 1000, &mut payment, &clock, s.ctx());
    payment.burn_for_testing();
    ts::return_shared(tier);
    ts::return_shared(fee_config);
    clock.destroy_for_testing();
    s.end();
}

/// A creator-configured period cannot reach the u64 expiry overflow
/// range.
#[test]
#[expected_failure(abort_code = 2, location = humming::subscriptions)]
fun subscription_period_too_long_rejected() {
    let mut s = ts::begin(ADMIN);

    s.next_tx(BOB);
    // One millisecond over the 10-year bound.
    let cap = subscriptions::create<SUI>(1000, 315_360_000_001, str(b""), s.ctx());
    transfer::public_transfer(cap, BOB);
    s.end();
}

/// Wallet rotation on a tier: future proceeds follow `set_recipient`.
#[test]
fun tier_recipient_change_redirects_proceeds() {
    let mut s = ts::begin(ADMIN);
    setup_platform(&mut s);
    let clock = new_clock(&mut s);

    s.next_tx(BOB);
    {
        let cap = subscriptions::create<SUI>(1000, DAY_MS, str(b""), s.ctx());
        transfer::public_transfer(cap, BOB);
    };
    s.next_tx(BOB);
    {
        let mut tier = s.take_shared<Tier<SUI>>();
        let cap = s.take_from_sender<TierCap>();
        subscriptions::set_recipient(&mut tier, &cap, CAROL);
        assert!(subscriptions::recipient(&tier) == CAROL);
        s.return_to_sender(cap);
        ts::return_shared(tier);
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

    // Carol — not Bob — received the creator share.
    s.next_tx(CAROL);
    {
        let proceeds = s.take_from_sender<Coin<SUI>>();
        assert!(proceeds.value() == 950);
        s.return_to_sender(proceeds);
    };

    clock.destroy_for_testing();
    s.end();
}

// === subscriber_only_rule ===

/// The Patreon flow end-to-end: Bob gates replies on his post to his
/// tier's active subscribers; Alice subscribes and can reply.
#[test]
fun subscriber_only_reply() {
    let mut s = ts::begin(ADMIN);
    setup_feed(&mut s);
    setup_platform(&mut s);
    let clock = new_clock(&mut s);

    s.next_tx(BOB);
    {
        let cap = subscriptions::create<SUI>(1000, DAY_MS, str(b""), s.ctx());
        transfer::public_transfer(cap, BOB);
    };
    let p1 = create_simple_post(&mut s, BOB, b"ipfs://subscriber-gated", &clock);
    s.next_tx(BOB);
    {
        let mut f = s.take_shared<Feed>();
        let rules_cap = feed::create_post_rules(&mut f, p1, s.ctx());
        transfer::public_transfer(rules_cap, BOB);
        ts::return_shared(f);
    };
    s.next_tx(BOB);
    {
        let f = s.take_shared<Feed>();
        let tier = s.take_shared<Tier<SUI>>();
        let set_id = feed::post_rules_of(&f, p1).destroy_some();
        let mut set = ts::take_shared_by_id<RuleSet<InteractPostOp>>(&s, set_id);
        let cap = s.take_from_sender<RuleSetCap>();
        subscriber_only_rule::add(&mut set, &cap, vector[object::id(&tier)], true);
        s.return_to_sender(cap);
        ts::return_shared(set);
        ts::return_shared(f);
        ts::return_shared(tier);
    };

    // Alice subscribes...
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

    // ...and replies to the gated post.
    s.next_tx(ALICE);
    {
        let mut f = s.take_shared<Feed>();
        let tier = s.take_shared<Tier<SUI>>();
        let feed_set = ts::take_shared_by_id<RuleSet<CreatePostOp>>(&s, feed::feed_rules_id(&f));
        let post_set_id = feed::post_rules_of(&f, p1).destroy_some();
        let post_set = ts::take_shared_by_id<RuleSet<InteractPostOp>>(&s, post_set_id);
        let (ticket, req) = feed::request_create_post(
            &f,
            str(b"ipfs://subscriber-reply"),
            option::some(p1),
            option::none(),
            option::none(),
            s.ctx(),
        );
        let mut parent_req = feed::make_parent_request(&ticket);
        subscriber_only_rule::prove(&post_set, &mut parent_req, &tier, &clock);
        let p2 = feed::execute_create_post_gated(
            &mut f,
            &feed_set,
            &post_set,
            ticket,
            req,
            parent_req,
            &clock,
        );
        assert!(feed::post_root(&feed::post(&f, p2)) == p1);
        ts::return_shared(f);
        ts::return_shared(tier);
        ts::return_shared(feed_set);
        ts::return_shared(post_set);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = 1, location = humming::subscriber_only_rule)]
fun subscriber_only_rejects_non_subscriber() {
    let mut s = ts::begin(ADMIN);
    setup_feed(&mut s);
    setup_platform(&mut s);
    let clock = new_clock(&mut s);

    s.next_tx(BOB);
    {
        let cap = subscriptions::create<SUI>(1000, DAY_MS, str(b""), s.ctx());
        transfer::public_transfer(cap, BOB);
    };
    let p1 = create_simple_post(&mut s, BOB, b"ipfs://subscriber-gated", &clock);
    s.next_tx(BOB);
    {
        let mut f = s.take_shared<Feed>();
        let rules_cap = feed::create_post_rules(&mut f, p1, s.ctx());
        transfer::public_transfer(rules_cap, BOB);
        ts::return_shared(f);
    };
    s.next_tx(BOB);
    {
        let f = s.take_shared<Feed>();
        let tier = s.take_shared<Tier<SUI>>();
        let set_id = feed::post_rules_of(&f, p1).destroy_some();
        let mut set = ts::take_shared_by_id<RuleSet<InteractPostOp>>(&s, set_id);
        let cap = s.take_from_sender<RuleSetCap>();
        subscriber_only_rule::add(&mut set, &cap, vector[object::id(&tier)], true);
        s.return_to_sender(cap);
        ts::return_shared(set);
        ts::return_shared(f);
        ts::return_shared(tier);
    };

    // Carol never subscribed; her prove must abort.
    s.next_tx(CAROL);
    let mut f = s.take_shared<Feed>();
    let tier = s.take_shared<Tier<SUI>>();
    let feed_set = ts::take_shared_by_id<RuleSet<CreatePostOp>>(&s, feed::feed_rules_id(&f));
    let post_set_id = feed::post_rules_of(&f, p1).destroy_some();
    let post_set = ts::take_shared_by_id<RuleSet<InteractPostOp>>(&s, post_set_id);
    let (ticket, req) = feed::request_create_post(
        &f,
        str(b"ipfs://intruder"),
        option::some(p1),
        option::none(),
        option::none(),
        s.ctx(),
    );
    let mut parent_req = feed::make_parent_request(&ticket);
    subscriber_only_rule::prove(&post_set, &mut parent_req, &tier, &clock);
    let _ = feed::execute_create_post_gated(
        &mut f,
        &feed_set,
        &post_set,
        ticket,
        req,
        parent_req,
        &clock,
    );
    ts::return_shared(f);
    ts::return_shared(tier);
    ts::return_shared(feed_set);
    ts::return_shared(post_set);
    clock.destroy_for_testing();
    s.end();
}

/// One rule instance, several accepted tiers: "silver OR gold
/// subscribers" — the multi-tier Patreon shape.
#[test]
fun subscriber_only_multi_tier_any_admits() {
    let mut s = ts::begin(ADMIN);
    setup_group(&mut s);
    setup_platform(&mut s);
    let clock = new_clock(&mut s);

    // Bob offers silver (1000/day) and gold (2000/day) tiers.
    s.next_tx(BOB);
    {
        let cap = subscriptions::create<SUI>(1000, DAY_MS, str(b"silver"), s.ctx());
        transfer::public_transfer(cap, BOB);
    };
    s.next_tx(BOB);
    let silver_id = {
        let t = s.take_shared<Tier<SUI>>();
        let id = object::id(&t);
        ts::return_shared(t);
        id
    };
    s.next_tx(BOB);
    {
        let cap = subscriptions::create<SUI>(2000, DAY_MS, str(b"gold"), s.ctx());
        transfer::public_transfer(cap, BOB);
    };
    s.next_tx(BOB);
    let gold_id = {
        let t = s.take_shared<Tier<SUI>>();
        let id = object::id(&t);
        ts::return_shared(t);
        id
    };

    // Group joining requires an active silver OR gold subscription.
    s.next_tx(ADMIN);
    {
        let mut set = s.take_shared<RuleSet<JoinGroupOp>>();
        let cap = s.take_from_sender<RuleSetCap>();
        subscriber_only_rule::add(&mut set, &cap, vector[silver_id, gold_id], true);
        s.return_to_sender(cap);
        ts::return_shared(set);
    };

    // Alice subscribes silver and joins with a silver proof.
    s.next_tx(ALICE);
    {
        let mut tier = ts::take_shared_by_id<Tier<SUI>>(&s, silver_id);
        let fee_config = s.take_shared<FeeConfig>();
        let mut payment = coin::mint_for_testing<SUI>(1000, s.ctx());
        subscriptions::subscribe(&mut tier, &fee_config, ALICE, 1000, &mut payment, &clock, s.ctx());
        payment.destroy_zero();
        ts::return_shared(tier);
        ts::return_shared(fee_config);
    };
    s.next_tx(ALICE);
    {
        let mut g = s.take_shared<Group>();
        let set = s.take_shared<RuleSet<JoinGroupOp>>();
        let tier = ts::take_shared_by_id<Tier<SUI>>(&s, silver_id);
        let (ticket, mut req) = group::request_join(&g, s.ctx());
        subscriber_only_rule::prove(&set, &mut req, &tier, &clock);
        group::execute_join(&mut g, &set, ticket, req, &clock);
        assert!(group::is_member(&g, ALICE));
        ts::return_shared(g);
        ts::return_shared(set);
        ts::return_shared(tier);
    };

    // Carol subscribes gold and joins with a gold proof.
    s.next_tx(CAROL);
    {
        let mut tier = ts::take_shared_by_id<Tier<SUI>>(&s, gold_id);
        let fee_config = s.take_shared<FeeConfig>();
        let mut payment = coin::mint_for_testing<SUI>(2000, s.ctx());
        subscriptions::subscribe(&mut tier, &fee_config, CAROL, 2000, &mut payment, &clock, s.ctx());
        payment.destroy_zero();
        ts::return_shared(tier);
        ts::return_shared(fee_config);
    };
    s.next_tx(CAROL);
    {
        let mut g = s.take_shared<Group>();
        let set = s.take_shared<RuleSet<JoinGroupOp>>();
        let tier = ts::take_shared_by_id<Tier<SUI>>(&s, gold_id);
        let (ticket, mut req) = group::request_join(&g, s.ctx());
        subscriber_only_rule::prove(&set, &mut req, &tier, &clock);
        group::execute_join(&mut g, &set, ticket, req, &clock);
        assert!(group::member_count(&g) == 2);
        ts::return_shared(g);
        ts::return_shared(set);
        ts::return_shared(tier);
    };

    clock.destroy_for_testing();
    s.end();
}

/// A subscription to a tier OUTSIDE the allowed list proves nothing.
#[test]
#[expected_failure(abort_code = 0, location = humming::subscriber_only_rule)]
fun subscriber_only_foreign_tier_rejected() {
    let mut s = ts::begin(ADMIN);
    setup_group(&mut s);
    setup_platform(&mut s);
    let clock = new_clock(&mut s);

    // Gate accepts only the silver tier...
    s.next_tx(BOB);
    {
        let cap = subscriptions::create<SUI>(1000, DAY_MS, str(b"silver"), s.ctx());
        transfer::public_transfer(cap, BOB);
    };
    s.next_tx(BOB);
    let silver_id = {
        let t = s.take_shared<Tier<SUI>>();
        let id = object::id(&t);
        ts::return_shared(t);
        id
    };
    s.next_tx(ADMIN);
    {
        let mut set = s.take_shared<RuleSet<JoinGroupOp>>();
        let cap = s.take_from_sender<RuleSetCap>();
        subscriber_only_rule::add(&mut set, &cap, vector[silver_id], true);
        s.return_to_sender(cap);
        ts::return_shared(set);
    };

    // ...but Alice subscribes to an unrelated bronze tier.
    s.next_tx(BOB);
    {
        let cap = subscriptions::create<SUI>(10, DAY_MS, str(b"bronze"), s.ctx());
        transfer::public_transfer(cap, BOB);
    };
    s.next_tx(ALICE);
    let bronze_id = {
        let mut tier = s.take_shared<Tier<SUI>>();
        let fee_config = s.take_shared<FeeConfig>();
        let mut payment = coin::mint_for_testing<SUI>(10, s.ctx());
        subscriptions::subscribe(&mut tier, &fee_config, ALICE, 10, &mut payment, &clock, s.ctx());
        payment.destroy_zero();
        let id = object::id(&tier);
        ts::return_shared(tier);
        ts::return_shared(fee_config);
        id
    };

    s.next_tx(ALICE);
    let mut g = s.take_shared<Group>();
    let set = s.take_shared<RuleSet<JoinGroupOp>>();
    let tier = ts::take_shared_by_id<Tier<SUI>>(&s, bronze_id);
    let (ticket, mut req) = group::request_join(&g, s.ctx());
    subscriber_only_rule::prove(&set, &mut req, &tier, &clock);
    group::execute_join(&mut g, &set, ticket, req, &clock);
    ts::return_shared(g);
    ts::return_shared(set);
    ts::return_shared(tier);
    clock.destroy_for_testing();
    s.end();
}

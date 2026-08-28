// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Tests for `humming::paid_posts`: the per-post paywall.
#[test_only]
module humming::paid_posts_tests;

use humming::feed::{Self, CreatePostOp, Feed};
use humming::paid_posts::{Self, PostPaywall};
use humming::platform::FeeConfig;
use humming::rules::RuleSet;
use humming::test_helpers::{str, new_clock, setup_platform, setup_feed, create_simple_post};
use sui::coin::{Self, Coin};
use sui::event;
use sui::sui::SUI;
use sui::test_scenario::{Self as ts, Scenario};

const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;
const CAROL: address = @0xCA401;

/// Alice posts and paywalls it at `price`. Returns the post id.
fun setup_paywalled_post(s: &mut Scenario, price: u64): u64 {
    let clock = new_clock(s);
    let p1 = create_simple_post(s, ALICE, b"ipfs://premium", &clock);
    clock.destroy_for_testing();
    s.next_tx(ALICE);
    let mut f = s.take_shared<Feed>();
    paid_posts::create<SUI>(&mut f, p1, price, s.ctx());
    ts::return_shared(f);
    p1
}

#[test]
fun paid_post_purchase_and_fee_split() {
    let mut s = ts::begin(ADMIN);
    setup_feed(&mut s);
    setup_platform(&mut s);
    let clock = new_clock(&mut s);

    let p1 = create_simple_post(&mut s, ALICE, b"ipfs://premium", &clock);

    // Alice paywalls her post at 500.
    s.next_tx(ALICE);
    {
        let mut f = s.take_shared<Feed>();
        paid_posts::create<SUI>(&mut f, p1, 500, s.ctx());
        assert!(feed::paywall_of(&f, p1).is_some());
        ts::return_shared(f);
    };

    // Bob buys it; change stays with him.
    s.next_tx(BOB);
    {
        let mut paywall = s.take_shared<PostPaywall<SUI>>();
        let fee_config = s.take_shared<FeeConfig>();
        let f = s.take_shared<Feed>();
        let mut payment = coin::mint_for_testing<SUI>(600, s.ctx());
        paid_posts::purchase(&mut paywall, &fee_config, &f, 500, &mut payment, s.ctx());
        assert!(paid_posts::has_purchased(&paywall, BOB));
        assert!(paid_posts::purchase_count(&paywall) == 1);
        assert!(payment.value() == 100);
        // The purchase event snapshots the content pointer at purchase
        // time — the buyer's evidence if the author edits afterwards.
        let evs = event::events_by_type<paid_posts::PostPurchased>();
        assert!(evs.length() == 1);
        assert!(paid_posts::purchase_event_content_uri(&evs[0]) == str(b"ipfs://premium"));
        payment.burn_for_testing();
        ts::return_shared(paywall);
        ts::return_shared(fee_config);
        ts::return_shared(f);
    };

    // Alice got 475 (95%), the treasury got 25 (5%).
    s.next_tx(ALICE);
    {
        let proceeds = s.take_from_sender<Coin<SUI>>();
        assert!(proceeds.value() == 475);
        s.return_to_sender(proceeds);
    };
    s.next_tx(ADMIN);
    {
        let cut = s.take_from_sender<Coin<SUI>>();
        assert!(cut.value() == 25);
        s.return_to_sender(cut);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = 4, location = humming::paid_posts)]
fun paid_post_double_purchase_aborts() {
    let mut s = ts::begin(ADMIN);
    setup_feed(&mut s);
    setup_platform(&mut s);
    let p1 = setup_paywalled_post(&mut s, 500);

    s.next_tx(BOB);
    let mut paywall = s.take_shared<PostPaywall<SUI>>();
    let fee_config = s.take_shared<FeeConfig>();
    let f = s.take_shared<Feed>();
    let mut payment = coin::mint_for_testing<SUI>(1000, s.ctx());
    paid_posts::purchase(&mut paywall, &fee_config, &f, 500, &mut payment, s.ctx());
    paid_posts::purchase(&mut paywall, &fee_config, &f, 500, &mut payment, s.ctx());
    payment.burn_for_testing();
    ts::return_shared(paywall);
    ts::return_shared(fee_config);
    ts::return_shared(f);
    let _ = p1;
    s.end();
}

#[test]
#[expected_failure(abort_code = 0, location = humming::paid_posts)]
fun paid_post_only_author_can_create() {
    let mut s = ts::begin(ADMIN);
    setup_feed(&mut s);
    setup_platform(&mut s);
    let clock = new_clock(&mut s);

    let p1 = create_simple_post(&mut s, ALICE, b"ipfs://premium", &clock);

    // Bob tries to paywall Alice's post.
    s.next_tx(BOB);
    let mut f = s.take_shared<Feed>();
    paid_posts::create<SUI>(&mut f, p1, 500, s.ctx());
    ts::return_shared(f);
    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = 3, location = humming::paid_posts)]
fun paid_post_closed_paywall_rejects() {
    let mut s = ts::begin(ADMIN);
    setup_feed(&mut s);
    setup_platform(&mut s);
    let p1 = setup_paywalled_post(&mut s, 500);

    s.next_tx(ALICE);
    {
        let mut paywall = s.take_shared<PostPaywall<SUI>>();
        paid_posts::set_active(&mut paywall, false, s.ctx());
        ts::return_shared(paywall);
    };

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
    let _ = p1;
    s.end();
}

#[test]
#[expected_failure(abort_code = 14, location = humming::feed)]
fun paid_post_duplicate_paywall_rejected() {
    let mut s = ts::begin(ADMIN);
    setup_feed(&mut s);
    setup_platform(&mut s);
    let clock = new_clock(&mut s);

    let p1 = create_simple_post(&mut s, ALICE, b"ipfs://premium", &clock);
    s.next_tx(ALICE);
    let mut f = s.take_shared<Feed>();
    paid_posts::create<SUI>(&mut f, p1, 500, s.ctx());
    paid_posts::create<SUI>(&mut f, p1, 900, s.ctx());
    ts::return_shared(f);
    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = 7, location = humming::paid_posts)]
fun paid_post_on_repost_rejected() {
    let mut s = ts::begin(ADMIN);
    setup_feed(&mut s);
    setup_platform(&mut s);
    let clock = new_clock(&mut s);

    let p1 = create_simple_post(&mut s, ALICE, b"ipfs://original", &clock);

    // Alice reposts her own post, then tries to sell the repost.
    s.next_tx(ALICE);
    let mut f = s.take_shared<Feed>();
    let set = ts::take_shared_by_id<RuleSet<CreatePostOp>>(&s, feed::feed_rules_id(&f));
    let (ticket, req) = feed::request_create_post(
        &f,
        str(b""),
        option::none(),
        option::none(),
        option::some(p1),
        s.ctx(),
    );
    let p2 = feed::execute_create_post(&mut f, &set, ticket, req, &clock);
    paid_posts::create<SUI>(&mut f, p2, 500, s.ctx());
    ts::return_shared(f);
    ts::return_shared(set);
    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = 10, location = humming::paid_posts)]
fun purchase_price_mismatch_aborts() {
    let mut s = ts::begin(ADMIN);
    setup_feed(&mut s);
    setup_platform(&mut s);
    let p1 = setup_paywalled_post(&mut s, 500);

    // Alice raises the price before Bob's purchase lands.
    s.next_tx(ALICE);
    {
        let mut paywall = s.take_shared<PostPaywall<SUI>>();
        paid_posts::set_price(&mut paywall, 900, s.ctx());
        ts::return_shared(paywall);
    };

    // Bob still expects 500.
    s.next_tx(BOB);
    let mut paywall = s.take_shared<PostPaywall<SUI>>();
    let fee_config = s.take_shared<FeeConfig>();
    let f = s.take_shared<Feed>();
    let mut payment = coin::mint_for_testing<SUI>(900, s.ctx());
    paid_posts::purchase(&mut paywall, &fee_config, &f, 500, &mut payment, s.ctx());
    payment.burn_for_testing();
    ts::return_shared(paywall);
    ts::return_shared(fee_config);
    ts::return_shared(f);
    let _ = p1;
    s.end();
}

// === Payout recipient rotation ===

/// Wallet rotation: the author redirects future proceeds; admin
/// authority stays with the author address.
#[test]
fun paywall_recipient_change_redirects_proceeds() {
    let mut s = ts::begin(ADMIN);
    setup_feed(&mut s);
    setup_platform(&mut s);
    let p1 = setup_paywalled_post(&mut s, 500);

    s.next_tx(ALICE);
    {
        let mut paywall = s.take_shared<PostPaywall<SUI>>();
        assert!(paid_posts::recipient(&paywall) == ALICE);
        paid_posts::set_recipient(&mut paywall, CAROL, s.ctx());
        assert!(paid_posts::recipient(&paywall) == CAROL);
        assert!(paid_posts::author(&paywall) == ALICE);
        assert!(event::events_by_type<paid_posts::PaywallRecipientChanged>().length() == 1);
        ts::return_shared(paywall);
    };

    s.next_tx(BOB);
    {
        let mut paywall = s.take_shared<PostPaywall<SUI>>();
        let fee_config = s.take_shared<FeeConfig>();
        let f = s.take_shared<Feed>();
        let mut payment = coin::mint_for_testing<SUI>(500, s.ctx());
        paid_posts::purchase(&mut paywall, &fee_config, &f, 500, &mut payment, s.ctx());
        payment.destroy_zero();
        ts::return_shared(paywall);
        ts::return_shared(fee_config);
        ts::return_shared(f);
    };

    // Carol — not Alice — received the creator share.
    s.next_tx(CAROL);
    {
        let proceeds = s.take_from_sender<Coin<SUI>>();
        assert!(proceeds.value() == 475);
        s.return_to_sender(proceeds);
    };

    let _ = p1;
    s.end();
}

#[test]
#[expected_failure(abort_code = 0, location = humming::paid_posts)]
fun paywall_set_recipient_non_author_fails() {
    let mut s = ts::begin(ADMIN);
    setup_feed(&mut s);
    setup_platform(&mut s);
    let p1 = setup_paywalled_post(&mut s, 500);

    s.next_tx(BOB);
    let mut paywall = s.take_shared<PostPaywall<SUI>>();
    paid_posts::set_recipient(&mut paywall, BOB, s.ctx());
    ts::return_shared(paywall);
    let _ = p1;
    s.end();
}

// === Failure-path completion ===

#[test]
#[expected_failure(abort_code = 5, location = humming::paid_posts)]
fun paid_post_author_cannot_buy() {
    let mut s = ts::begin(ADMIN);
    setup_feed(&mut s);
    setup_platform(&mut s);
    let p1 = setup_paywalled_post(&mut s, 500);

    s.next_tx(ALICE);
    let mut paywall = s.take_shared<PostPaywall<SUI>>();
    let fee_config = s.take_shared<FeeConfig>();
    let f = s.take_shared<Feed>();
    let mut payment = coin::mint_for_testing<SUI>(500, s.ctx());
    paid_posts::purchase(&mut paywall, &fee_config, &f, 500, &mut payment, s.ctx());
    payment.burn_for_testing();
    ts::return_shared(paywall);
    ts::return_shared(fee_config);
    ts::return_shared(f);
    let _ = p1;
    s.end();
}

/// A deleted post stops selling even though its paywall object stays
/// open.
#[test]
#[expected_failure(abort_code = 1, location = humming::paid_posts)]
fun paid_post_deleted_post_stops_selling() {
    let mut s = ts::begin(ADMIN);
    setup_feed(&mut s);
    setup_platform(&mut s);
    let p1 = setup_paywalled_post(&mut s, 500);

    s.next_tx(ALICE);
    {
        let mut f = s.take_shared<Feed>();
        feed::delete_post(&mut f, p1, s.ctx());
        ts::return_shared(f);
    };

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
    s.end();
}

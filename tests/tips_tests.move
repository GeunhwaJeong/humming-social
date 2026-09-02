// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Tests for `humming::tips`: the event-emitting payment wrapper.
#[test_only]
module humming::tips_tests;

use humming::feed::Feed;
use humming::platform::FeeConfig;
use humming::test_helpers::{new_clock, setup_platform, setup_feed, create_simple_post};
use humming::tips;
use sui::coin::{Self, Coin};
use sui::event;
use sui::sui::SUI;
use sui::test_scenario::{Self as ts};

const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;
const CAROL: address = @0xCA401;

#[test]
fun tips_flow_and_events() {
    let mut s = ts::begin(ADMIN);
    setup_platform(&mut s);
    setup_feed(&mut s);
    let clock = new_clock(&mut s);
    let post = create_simple_post(&mut s, ALICE, b"ipfs://tippable", &clock);

    // Post-attributed tip: recipient is derived from the post author,
    // and the event trail carries the attribution.
    s.next_tx(BOB);
    {
        let f = s.take_shared<Feed>();
        let fee_config = s.take_shared<FeeConfig>();
        let mut payment = coin::mint_for_testing<SUI>(1000, s.ctx());
        tips::tip_post(&fee_config, &f, post, 1000, &mut payment, s.ctx());
        payment.burn_for_testing();
        ts::return_shared(fee_config);
        ts::return_shared(f);
        let sent = event::events_by_type<tips::TipSent>();
        assert!(sent.length() == 1);
        assert!(tips::tip_event_to(&sent[0]) == ALICE);
        assert!(tips::tip_event_amount(&sent[0]) == 1000);
        assert!(tips::tip_event_fee(&sent[0]) == 50);
        assert!(tips::tip_event_post_id(&sent[0]) == option::some(post));
    };

    // Profile-level tip, no post attribution.
    s.next_tx(BOB);
    {
        let fee_config = s.take_shared<FeeConfig>();
        let mut payment = coin::mint_for_testing<SUI>(200, s.ctx());
        tips::tip(&fee_config, CAROL, 200, &mut payment, s.ctx());
        payment.burn_for_testing();
        ts::return_shared(fee_config);
        let sent = event::events_by_type<tips::TipSent>();
        assert!(sent.length() == 1);
        assert!(tips::tip_event_to(&sent[0]) == CAROL);
        assert!(tips::tip_event_post_id(&sent[0]) == option::none());
    };

    // Creator payouts arrived net of the 5% platform cut.
    s.next_tx(ADMIN);
    {
        let alice_cut = s.take_from_address<Coin<SUI>>(ALICE);
        assert!(alice_cut.value() == 950);
        ts::return_to_address(ALICE, alice_cut);
        let carol_cut = s.take_from_address<Coin<SUI>>(CAROL);
        assert!(carol_cut.value() == 190);
        ts::return_to_address(CAROL, carol_cut);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = 1, location = humming::tips)]
fun tips_self_tip_aborts() {
    let mut s = ts::begin(ADMIN);
    setup_platform(&mut s);

    s.next_tx(BOB);
    let fee_config = s.take_shared<FeeConfig>();
    let mut payment = coin::mint_for_testing<SUI>(100, s.ctx());
    tips::tip(&fee_config, BOB, 100, &mut payment, s.ctx());
    payment.burn_for_testing();
    ts::return_shared(fee_config);
    s.end();
}

#[test]
#[expected_failure(abort_code = 0, location = humming::tips)]
fun tips_zero_amount_aborts() {
    let mut s = ts::begin(ADMIN);
    setup_platform(&mut s);

    s.next_tx(BOB);
    let fee_config = s.take_shared<FeeConfig>();
    let mut payment = coin::mint_for_testing<SUI>(100, s.ctx());
    tips::tip(&fee_config, ALICE, 0, &mut payment, s.ctx());
    payment.burn_for_testing();
    ts::return_shared(fee_config);
    s.end();
}

#[test]
#[expected_failure(abort_code = 2, location = humming::tips)]
fun tips_unknown_post_aborts() {
    let mut s = ts::begin(ADMIN);
    setup_platform(&mut s);
    setup_feed(&mut s);

    s.next_tx(BOB);
    let f = s.take_shared<Feed>();
    let fee_config = s.take_shared<FeeConfig>();
    let mut payment = coin::mint_for_testing<SUI>(100, s.ctx());
    tips::tip_post(&fee_config, &f, 999, 100, &mut payment, s.ctx());
    payment.burn_for_testing();
    ts::return_shared(fee_config);
    ts::return_shared(f);
    s.end();
}

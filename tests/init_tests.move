// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Tests for the package initializer and the `Username` trading stack
/// it sets up (display, transfer policy, kiosk flow).
#[test_only]
module humming::init_tests;

use humming::humming::init_for_testing;
use humming::namespace::{Self, CreateUsernameOp, Namespace, Username};
use humming::platform::{Self, FeeConfig, FeeConfigCap};
use humming::rules::RuleSet;
use humming::test_helpers::{str, setup_namespace};
use humming::username_validation_rule;
use haneul::coin;
use haneul::display::Display;
use haneul::haneul::HANEUL;
use haneul::kiosk::{Self, Kiosk, KioskOwnerCap};
use haneul::package::Publisher;
use haneul::test_scenario::{Self as ts};
use haneul::transfer_policy::TransferPolicy;

const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;

#[test]
fun init_creates_publisher_display_and_policy() {
    let mut s = ts::begin(ADMIN);
    s.next_tx(ADMIN);
    init_for_testing(s.ctx());

    s.next_tx(ADMIN);
    {
        let publisher = s.take_from_sender<Publisher>();
        assert!(publisher.from_package<Username>());
        let display = s.take_from_sender<Display<Username>>();
        // The policy is shared (kiosks need it at purchase time); its
        // cap stays with the deployer for adding rules later.
        let policy = s.take_shared<TransferPolicy<Username>>();
        // The canonical fee config: 5% launch fee, deployer treasury,
        // lever with the deployer, breaker open.
        let fee_config = s.take_shared<FeeConfig>();
        assert!(platform::fee_bps(&fee_config) == 500);
        assert!(platform::treasury(&fee_config) == ADMIN);
        assert!(!platform::is_paused(&fee_config));
        let fee_cap = s.take_from_sender<FeeConfigCap>();
        s.return_to_sender(publisher);
        s.return_to_sender(display);
        s.return_to_sender(fee_cap);
        ts::return_shared(policy);
        ts::return_shared(fee_config);
    };

    s.end();
}

/// End-to-end marketplace flow: a username minted through the normal
/// rule-gated path is listed on a kiosk, bought by another account
/// through the shared transfer policy, and the seller collects the
/// proceeds.
#[test]
fun username_kiosk_trade() {
    let mut s = ts::begin(ADMIN);
    s.next_tx(ADMIN);
    init_for_testing(s.ctx());
    setup_namespace(&mut s);

    // Alice mints "alice" and lists it on her kiosk for 5000.
    s.next_tx(ALICE);
    let username_id = {
        let mut ns = s.take_shared<Namespace>();
        let set = s.take_shared<RuleSet<CreateUsernameOp>>();
        let (ticket, mut req) = namespace::request_create_username(&ns, str(b"alice"), s.ctx());
        username_validation_rule::prove(&set, &ticket, &mut req);
        let username = namespace::execute_create_username(&mut ns, &set, ticket, req, s.ctx());
        let id = object::id(&username);
        let (mut k, kiosk_cap) = kiosk::new(s.ctx());
        k.place_and_list(&kiosk_cap, username, 5000);
        transfer::public_share_object(k);
        transfer::public_transfer(kiosk_cap, ALICE);
        ts::return_shared(ns);
        ts::return_shared(set);
        id
    };

    // Bob buys it through the shared transfer policy.
    s.next_tx(BOB);
    {
        let mut k = s.take_shared<Kiosk>();
        let policy = s.take_shared<TransferPolicy<Username>>();
        let payment = coin::mint_for_testing<HANEUL>(5000, s.ctx());
        let (username, request) = k.purchase<Username>(username_id, payment);
        policy.confirm_request(request);
        assert!(namespace::username_name(&username) == str(b"alice"));
        transfer::public_transfer(username, BOB);
        ts::return_shared(k);
        ts::return_shared(policy);
    };

    // Alice collects the sale proceeds from her kiosk.
    s.next_tx(ALICE);
    {
        let mut k = s.take_shared<Kiosk>();
        let kiosk_cap = s.take_from_sender<KioskOwnerCap>();
        let proceeds = k.withdraw(&kiosk_cap, option::some(5000), s.ctx());
        assert!(proceeds.value() == 5000);
        proceeds.burn_for_testing();
        s.return_to_sender(kiosk_cap);
        ts::return_shared(k);
    };

    s.end();
}

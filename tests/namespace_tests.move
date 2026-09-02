// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Tests for `humming::namespace`: minting, assignment, trading paths,
/// and the primitive-level name floor.
#[test_only]
module humming::namespace_tests;

use humming::namespace::{Self, CreateUsernameOp, Namespace, Username};
use humming::rules::RuleSet;
use humming::test_helpers::{str, setup_namespace};
use humming::username_validation_rule;
use sui::test_scenario::{Self as ts};

const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;

#[test]
fun namespace_full_lifecycle() {
    let mut s = ts::begin(ADMIN);
    setup_namespace(&mut s);

    // Alice mints and assigns a username.
    s.next_tx(ALICE);
    {
        let mut ns = s.take_shared<Namespace>();
        let set = s.take_shared<RuleSet<CreateUsernameOp>>();
        let (ticket, mut req) = namespace::request_create_username(&ns, str(b"alice"), s.ctx());
        username_validation_rule::prove(&set, &ticket, &mut req);
        let username = namespace::execute_create_username(&mut ns, &set, ticket, req, s.ctx());
        namespace::assign(&mut ns, &username, s.ctx());
        assert!(namespace::account_of(&ns, str(b"alice")) == option::some(ALICE));
        assert!(namespace::username_of(&ns, ALICE) == option::some(str(b"alice")));
        assert!(namespace::is_taken(&ns, str(b"alice")));
        transfer::public_transfer(username, ALICE);
        ts::return_shared(ns);
        ts::return_shared(set);
    };

    // Alice unassigns and burns; the name frees up.
    s.next_tx(ALICE);
    {
        let mut ns = s.take_shared<Namespace>();
        let username = s.take_from_sender<Username>();
        namespace::unassign_self(&mut ns, s.ctx());
        assert!(namespace::account_of(&ns, str(b"alice")).is_none());
        namespace::burn(&mut ns, username);
        assert!(!namespace::is_taken(&ns, str(b"alice")));
        ts::return_shared(ns);
    };

    s.end();
}

#[test]
fun namespace_admin_can_bypass_rules() {
    let mut s = ts::begin(ADMIN);
    setup_namespace(&mut s);

    // "hq" (2 chars) violates the min-length rule, but admin minting
    // bypasses creation rules (reserved-handle use case).
    s.next_tx(ADMIN);
    let mut ns = s.take_shared<Namespace>();
    let admin_cap = s.take_from_sender<namespace::NamespaceAdminCap>();
    let username = namespace::admin_create_username(&mut ns, &admin_cap, str(b"hq"), s.ctx());
    assert!(namespace::is_taken(&ns, str(b"hq")));
    transfer::public_transfer(username, ADMIN);
    s.return_to_sender(admin_cap);
    ts::return_shared(ns);
    s.end();
}

#[test]
#[expected_failure(abort_code = 2, location = humming::username_validation_rule)]
fun namespace_rejects_invalid_charset() {
    let mut s = ts::begin(ADMIN);
    setup_namespace(&mut s);

    s.next_tx(ALICE);
    let mut ns = s.take_shared<Namespace>();
    let set = s.take_shared<RuleSet<CreateUsernameOp>>();
    // '!' violates the charset rule. (Uppercase is rejected one layer
    // earlier, by the namespace primitive itself — covered below.)
    let (ticket, mut req) = namespace::request_create_username(&ns, str(b"al!ce"), s.ctx());
    username_validation_rule::prove(&set, &ticket, &mut req);
    let username = namespace::execute_create_username(&mut ns, &set, ticket, req, s.ctx());
    transfer::public_transfer(username, ALICE);
    ts::return_shared(ns);
    ts::return_shared(set);
    s.end();
}

/// Case-squatting floor: "Alice" is rejected by the primitive itself,
/// before any validation rule runs.
#[test]
#[expected_failure(abort_code = 11, location = humming::namespace)]
fun namespace_rejects_uppercase() {
    let mut s = ts::begin(ADMIN);
    setup_namespace(&mut s);

    s.next_tx(ALICE);
    let mut ns = s.take_shared<Namespace>();
    let set = s.take_shared<RuleSet<CreateUsernameOp>>();
    let (ticket, mut req) = namespace::request_create_username(&ns, str(b"Alice"), s.ctx());
    username_validation_rule::prove(&set, &ticket, &mut req);
    let username = namespace::execute_create_username(&mut ns, &set, ticket, req, s.ctx());
    transfer::public_transfer(username, ALICE);
    ts::return_shared(ns);
    ts::return_shared(set);
    s.end();
}

/// The floor holds even on a namespace whose admin never attached a
/// validation rule — and even against the admin's own bypass mint.
#[test]
#[expected_failure(abort_code = 11, location = humming::namespace)]
fun namespace_uppercase_rejected_without_rules() {
    let mut s = ts::begin(ADMIN);
    s.next_tx(ADMIN);
    {
        let (admin_cap, rules_cap) = namespace::create(str(b"bare"), str(b""), s.ctx());
        transfer::public_transfer(admin_cap, ADMIN);
        transfer::public_transfer(rules_cap, ADMIN);
    };

    s.next_tx(ADMIN);
    let mut ns = s.take_shared<Namespace>();
    let admin_cap = s.take_from_sender<namespace::NamespaceAdminCap>();
    let username = namespace::admin_create_username(&mut ns, &admin_cap, str(b"Alice"), s.ctx());
    transfer::public_transfer(username, ADMIN);
    s.return_to_sender(admin_cap);
    ts::return_shared(ns);
    s.end();
}

#[test]
#[expected_failure(abort_code = 2, location = humming::rules)]
fun namespace_rejects_unstamped_request() {
    let mut s = ts::begin(ADMIN);
    setup_namespace(&mut s);

    // Skipping the required rule's prove step must abort at confirm.
    s.next_tx(ALICE);
    let mut ns = s.take_shared<Namespace>();
    let set = s.take_shared<RuleSet<CreateUsernameOp>>();
    let (ticket, req) = namespace::request_create_username(&ns, str(b"alice"), s.ctx());
    let username = namespace::execute_create_username(&mut ns, &set, ticket, req, s.ctx());
    transfer::public_transfer(username, ALICE);
    ts::return_shared(ns);
    ts::return_shared(set);
    s.end();
}

#[test]
#[expected_failure(abort_code = 0, location = humming::namespace)]
fun namespace_rejects_duplicate_username() {
    let mut s = ts::begin(ADMIN);
    setup_namespace(&mut s);

    s.next_tx(ADMIN);
    {
        let mut ns = s.take_shared<Namespace>();
        let admin_cap = s.take_from_sender<namespace::NamespaceAdminCap>();
        let username = namespace::admin_create_username(&mut ns, &admin_cap, str(b"alice"), s.ctx());
        transfer::public_transfer(username, ADMIN);
        s.return_to_sender(admin_cap);
        ts::return_shared(ns);
    };
    s.next_tx(ALICE);
    {
        let mut ns = s.take_shared<Namespace>();
        let set = s.take_shared<RuleSet<CreateUsernameOp>>();
        let (ticket, mut req) = namespace::request_create_username(&ns, str(b"alice"), s.ctx());
        username_validation_rule::prove(&set, &ticket, &mut req);
        let username = namespace::execute_create_username(&mut ns, &set, ticket, req, s.ctx());
        transfer::public_transfer(username, ALICE);
        ts::return_shared(ns);
        ts::return_shared(set);
    };
    s.end();
}

#[test]
#[expected_failure(abort_code = 8, location = humming::namespace)]
fun namespace_cannot_burn_assigned_username() {
    let mut s = ts::begin(ADMIN);
    setup_namespace(&mut s);

    s.next_tx(ALICE);
    let mut ns = s.take_shared<Namespace>();
    let set = s.take_shared<RuleSet<CreateUsernameOp>>();
    let (ticket, mut req) = namespace::request_create_username(&ns, str(b"alice"), s.ctx());
    username_validation_rule::prove(&set, &ticket, &mut req);
    let username = namespace::execute_create_username(&mut ns, &set, ticket, req, s.ctx());
    namespace::assign(&mut ns, &username, s.ctx());
    // Burning while still assigned must abort.
    namespace::burn(&mut ns, username);
    ts::return_shared(ns);
    ts::return_shared(set);
    s.end();
}

#[test]
fun namespace_buyer_unassigns_and_reassigns() {
    let mut s = ts::begin(ADMIN);
    setup_namespace(&mut s);

    // Alice mints "alice" and assigns it to herself.
    s.next_tx(ALICE);
    {
        let mut ns = s.take_shared<Namespace>();
        let set = s.take_shared<RuleSet<CreateUsernameOp>>();
        let (ticket, mut req) = namespace::request_create_username(&ns, str(b"alice"), s.ctx());
        username_validation_rule::prove(&set, &ticket, &mut req);
        let username = namespace::execute_create_username(&mut ns, &set, ticket, req, s.ctx());
        namespace::assign(&mut ns, &username, s.ctx());
        // ...then sells/transfers the Username object to Bob.
        transfer::public_transfer(username, BOB);
        ts::return_shared(ns);
        ts::return_shared(set);
    };

    // Bob, holding the object, unassigns it from Alice and takes it.
    s.next_tx(BOB);
    {
        let mut ns = s.take_shared<Namespace>();
        let username = s.take_from_sender<Username>();
        namespace::unassign(&mut ns, &username);
        assert!(namespace::username_of(&ns, ALICE).is_none());
        namespace::assign(&mut ns, &username, s.ctx());
        assert!(namespace::account_of(&ns, str(b"alice")) == option::some(BOB));
        s.return_to_sender(username);
        ts::return_shared(ns);
    };

    s.end();
}

// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module humming::humming_tests;

use humming::feed::{Self, CreatePostOp, Feed, InteractPostOp};
use humming::followers_only_rule;
use humming::graph::{Self, FollowOp, Graph};
use humming::group::{Self, Group, JoinGroupOp};
use humming::humming::init_for_testing;
use humming::locked_token_rule::{Self, Lock};
use humming::namespace::{Self, CreateUsernameOp, Namespace, Username};
use humming::profile::{Self, Profile};
use humming::rules::{Self, RuleSet, RuleSetCap};
use humming::simple_payment_rule;
use humming::token_gated_rule;
use humming::username_validation_rule;
use std::string::{Self, String};
use haneul::clock::{Self, Clock};
use haneul::coin::{Self, Coin};
use haneul::display::Display;
use haneul::event;
use haneul::haneul::HANEUL;
use haneul::kiosk::{Self, Kiosk, KioskOwnerCap};
use haneul::package::Publisher;
use haneul::test_scenario::{Self as ts, Scenario};
use haneul::transfer_policy::TransferPolicy;

const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;
const CAROL: address = @0xCA401;

fun str(bytes: vector<u8>): String { string::utf8(bytes) }

/// Test-only rule witness: each phantom instantiation has a distinct
/// `TypeName`, giving an unbounded supply of rule identities for
/// exercising `MAX_RULES`.
public struct FillerRule<phantom T> has drop {}

fun new_clock(s: &mut Scenario): Clock {
    clock::create_for_testing(s.ctx())
}

// === Namespace ===

fun setup_namespace(s: &mut Scenario) {
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
    // Uppercase 'A' violates the charset rule.
    let (ticket, mut req) = namespace::request_create_username(&ns, str(b"Alice"), s.ctx());
    username_validation_rule::prove(&set, &ticket, &mut req);
    let username = namespace::execute_create_username(&mut ns, &set, ticket, req, s.ctx());
    transfer::public_transfer(username, ALICE);
    ts::return_shared(ns);
    ts::return_shared(set);
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

// === Graph ===

fun setup_graph(s: &mut Scenario) {
    s.next_tx(ADMIN);
    let (admin_cap, rules_cap) = graph::create(str(b""), s.ctx());
    transfer::public_transfer(admin_cap, ADMIN);
    transfer::public_transfer(rules_cap, ADMIN);
}

/// Follow with no per-account rules configured on the target.
fun follow(s: &mut Scenario, follower: address, target: address, clock: &Clock) {
    s.next_tx(follower);
    let mut g = s.take_shared<Graph>();
    let set = ts::take_shared_by_id<RuleSet<FollowOp>>(s, graph::graph_rules_id(&g));
    let (ticket, req) = graph::request_follow(&g, target, s.ctx());
    graph::execute_follow(&mut g, &set, ticket, req, clock, s.ctx());
    ts::return_shared(g);
    ts::return_shared(set);
}

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
    let clock = new_clock(&mut s);

    // Bob gates follows on himself: 1000 GEUNHWA to follow.
    s.next_tx(BOB);
    {
        let mut g = s.take_shared<Graph>();
        let rules_cap = graph::create_my_follow_rules(&mut g, s.ctx());
        transfer::public_transfer(rules_cap, BOB);
        ts::return_shared(g);
    };
    s.next_tx(BOB);
    {
        let g = s.take_shared<Graph>();
        let set_id = graph::follow_rules_of(&g, BOB).destroy_some();
        let mut set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, set_id);
        let cap = s.take_from_sender<RuleSetCap>();
        simple_payment_rule::add<FollowOp, HANEUL>(&mut set, &cap, 1000, BOB, true);
        s.return_to_sender(cap);
        ts::return_shared(set);
        ts::return_shared(g);
    };

    // Alice pays and follows.
    s.next_tx(ALICE);
    {
        let mut g = s.take_shared<Graph>();
        let graph_set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, graph::graph_rules_id(&g));
        let bob_set_id = graph::follow_rules_of(&g, BOB).destroy_some();
        let bob_set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, bob_set_id);
        // Pays with a larger coin: the fee is split off, change stays.
        let mut payment = coin::mint_for_testing<HANEUL>(1500, s.ctx());
        let (ticket, mut req) = graph::request_follow(&g, BOB, s.ctx());
        simple_payment_rule::pay(&bob_set, &mut req, &mut payment, s.ctx());
        assert!(payment.value() == 500);
        graph::execute_follow_gated(&mut g, &graph_set, &bob_set, ticket, req, &clock, s.ctx());
        assert!(graph::is_following(&g, ALICE, BOB));
        payment.burn_for_testing();
        ts::return_shared(g);
        ts::return_shared(graph_set);
        ts::return_shared(bob_set);
    };

    // Bob received the payment.
    s.next_tx(BOB);
    {
        let payment = s.take_from_sender<Coin<HANEUL>>();
        assert!(payment.value() == 1000);
        s.return_to_sender(payment);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = 0, location = humming::simple_payment_rule)]
fun graph_paid_follow_wrong_amount() {
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
    s.next_tx(BOB);
    {
        let g = s.take_shared<Graph>();
        let set_id = graph::follow_rules_of(&g, BOB).destroy_some();
        let mut set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, set_id);
        let cap = s.take_from_sender<RuleSetCap>();
        simple_payment_rule::add<FollowOp, HANEUL>(&mut set, &cap, 1000, BOB, true);
        s.return_to_sender(cap);
        ts::return_shared(set);
        ts::return_shared(g);
    };

    // Underpaying must abort.
    s.next_tx(ALICE);
    let mut g = s.take_shared<Graph>();
    let graph_set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, graph::graph_rules_id(&g));
    let bob_set_id = graph::follow_rules_of(&g, BOB).destroy_some();
    let bob_set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, bob_set_id);
    let mut payment = coin::mint_for_testing<HANEUL>(999, s.ctx());
    let (ticket, mut req) = graph::request_follow(&g, BOB, s.ctx());
    simple_payment_rule::pay(&bob_set, &mut req, &mut payment, s.ctx());
    graph::execute_follow_gated(&mut g, &graph_set, &bob_set, ticket, req, &clock, s.ctx());
    payment.burn_for_testing();
    ts::return_shared(g);
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

// === Feed ===

fun setup_feed(s: &mut Scenario) {
    s.next_tx(ADMIN);
    let (admin_cap, rules_cap) = feed::create(str(b""), s.ctx());
    transfer::public_transfer(admin_cap, ADMIN);
    transfer::public_transfer(rules_cap, ADMIN);
}

fun create_simple_post(s: &mut Scenario, author: address, content: vector<u8>, clock: &Clock): u64 {
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

#[test]
fun feed_post_reply_quote_repost_roots() {
    let mut s = ts::begin(ADMIN);
    setup_feed(&mut s);
    let clock = new_clock(&mut s);

    let p1 = create_simple_post(&mut s, ALICE, b"ipfs://original", &clock);

    // Bob replies to p1: joins Alice's thread.
    s.next_tx(BOB);
    {
        let mut f = s.take_shared<Feed>();
        let set = ts::take_shared_by_id<RuleSet<CreatePostOp>>(&s, feed::feed_rules_id(&f));
        let (ticket, req) = feed::request_create_post(
            &f,
            str(b"ipfs://reply"),
            option::some(p1),
            option::none(),
            option::none(),
            s.ctx(),
        );
        let p2 = feed::execute_create_post(&mut f, &set, ticket, req, &clock);
        let post = feed::post(&f, p2);
        assert!(feed::post_root(&post) == p1);
        assert!(feed::post_author(&post) == BOB);

        // Carol quotes p1: starts her own thread (root = self).
        s.next_tx(CAROL);
        let (ticket, req) = feed::request_create_post(
            &f,
            str(b"ipfs://quote"),
            option::none(),
            option::some(p1),
            option::none(),
            s.ctx(),
        );
        let p3 = feed::execute_create_post(&mut f, &set, ticket, req, &clock);
        assert!(feed::post_root(&feed::post(&f, p3)) == p3);

        // Carol reposts p1: no content, joins the thread.
        let (ticket, req) = feed::request_create_post(
            &f,
            str(b""),
            option::none(),
            option::none(),
            option::some(p1),
            s.ctx(),
        );
        let p4 = feed::execute_create_post(&mut f, &set, ticket, req, &clock);
        assert!(feed::post_root(&feed::post(&f, p4)) == p1);
        assert!(feed::post_count(&f) == 4);

        ts::return_shared(f);
        ts::return_shared(set);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
fun feed_edit_and_delete() {
    let mut s = ts::begin(ADMIN);
    setup_feed(&mut s);
    let clock = new_clock(&mut s);

    let p1 = create_simple_post(&mut s, ALICE, b"ipfs://v1", &clock);

    s.next_tx(ALICE);
    {
        let mut f = s.take_shared<Feed>();
        feed::edit_post(&mut f, p1, str(b"ipfs://v2"), &clock, s.ctx());
        assert!(feed::post_content_uri(&feed::post(&f, p1)) == str(b"ipfs://v2"));
        feed::delete_post(&mut f, p1, s.ctx());
        assert!(!feed::post_exists(&f, p1));
        ts::return_shared(f);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = 1, location = humming::feed)]
fun feed_edit_by_non_author_fails() {
    let mut s = ts::begin(ADMIN);
    setup_feed(&mut s);
    let clock = new_clock(&mut s);

    let p1 = create_simple_post(&mut s, ALICE, b"ipfs://v1", &clock);

    s.next_tx(BOB);
    let mut f = s.take_shared<Feed>();
    feed::edit_post(&mut f, p1, str(b"ipfs://hacked"), &clock, s.ctx());
    ts::return_shared(f);
    clock.destroy_for_testing();
    s.end();
}

/// Full cross-primitive flow: Alice gates replies on her post to her
/// followers (via the graph); Bob follows and can reply.
#[test]
fun feed_followers_only_reply() {
    let mut s = ts::begin(ADMIN);
    setup_feed(&mut s);
    setup_graph(&mut s);
    let clock = new_clock(&mut s);

    let p1 = create_simple_post(&mut s, ALICE, b"ipfs://gated", &clock);

    // Alice creates the post's reply rule set and adds followers-only.
    s.next_tx(ALICE);
    {
        let mut f = s.take_shared<Feed>();
        let rules_cap = feed::create_post_rules(&mut f, p1, s.ctx());
        transfer::public_transfer(rules_cap, ALICE);
        ts::return_shared(f);
    };
    s.next_tx(ALICE);
    {
        let f = s.take_shared<Feed>();
        let g = s.take_shared<Graph>();
        let set_id = feed::post_rules_of(&f, p1).destroy_some();
        let mut set = ts::take_shared_by_id<RuleSet<InteractPostOp>>(&s, set_id);
        let cap = s.take_from_sender<RuleSetCap>();
        followers_only_rule::add(&mut set, &cap, object::id(&g), true);
        s.return_to_sender(cap);
        ts::return_shared(set);
        ts::return_shared(f);
        ts::return_shared(g);
    };

    // Bob follows Alice, then replies to the gated post.
    follow(&mut s, BOB, ALICE, &clock);

    s.next_tx(BOB);
    {
        let mut f = s.take_shared<Feed>();
        let g = s.take_shared<Graph>();
        let feed_set = ts::take_shared_by_id<RuleSet<CreatePostOp>>(&s, feed::feed_rules_id(&f));
        let post_set_id = feed::post_rules_of(&f, p1).destroy_some();
        let post_set = ts::take_shared_by_id<RuleSet<InteractPostOp>>(&s, post_set_id);
        let (ticket, req) = feed::request_create_post(
            &f,
            str(b"ipfs://reply-from-follower"),
            option::some(p1),
            option::none(),
            option::none(),
            s.ctx(),
        );
        let mut parent_req = feed::make_parent_request(&ticket);
        followers_only_rule::prove(&post_set, &ticket, &mut parent_req, &g);
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
        ts::return_shared(g);
        ts::return_shared(feed_set);
        ts::return_shared(post_set);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = 1, location = humming::followers_only_rule)]
fun feed_followers_only_rejects_non_follower() {
    let mut s = ts::begin(ADMIN);
    setup_feed(&mut s);
    setup_graph(&mut s);
    let clock = new_clock(&mut s);

    let p1 = create_simple_post(&mut s, ALICE, b"ipfs://gated", &clock);

    s.next_tx(ALICE);
    {
        let mut f = s.take_shared<Feed>();
        let rules_cap = feed::create_post_rules(&mut f, p1, s.ctx());
        transfer::public_transfer(rules_cap, ALICE);
        ts::return_shared(f);
    };
    s.next_tx(ALICE);
    {
        let f = s.take_shared<Feed>();
        let g = s.take_shared<Graph>();
        let set_id = feed::post_rules_of(&f, p1).destroy_some();
        let mut set = ts::take_shared_by_id<RuleSet<InteractPostOp>>(&s, set_id);
        let cap = s.take_from_sender<RuleSetCap>();
        followers_only_rule::add(&mut set, &cap, object::id(&g), true);
        s.return_to_sender(cap);
        ts::return_shared(set);
        ts::return_shared(f);
        ts::return_shared(g);
    };

    // Carol does NOT follow Alice; her prove must abort.
    s.next_tx(CAROL);
    let mut f = s.take_shared<Feed>();
    let g = s.take_shared<Graph>();
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
    followers_only_rule::prove(&post_set, &ticket, &mut parent_req, &g);
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
    ts::return_shared(g);
    ts::return_shared(feed_set);
    ts::return_shared(post_set);
    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = 5, location = humming::feed)]
fun feed_cannot_bypass_parent_rules() {
    let mut s = ts::begin(ADMIN);
    setup_feed(&mut s);
    let clock = new_clock(&mut s);

    let p1 = create_simple_post(&mut s, ALICE, b"ipfs://gated", &clock);

    s.next_tx(ALICE);
    {
        let mut f = s.take_shared<Feed>();
        let rules_cap = feed::create_post_rules(&mut f, p1, s.ctx());
        transfer::public_transfer(rules_cap, ALICE);
        ts::return_shared(f);
    };

    // Replying to a gated post via the non-gated path must abort.
    s.next_tx(BOB);
    let mut f = s.take_shared<Feed>();
    let set = ts::take_shared_by_id<RuleSet<CreatePostOp>>(&s, feed::feed_rules_id(&f));
    let (ticket, req) = feed::request_create_post(
        &f,
        str(b"ipfs://bypass"),
        option::some(p1),
        option::none(),
        option::none(),
        s.ctx(),
    );
    let _ = feed::execute_create_post(&mut f, &set, ticket, req, &clock);
    ts::return_shared(f);
    ts::return_shared(set);
    clock.destroy_for_testing();
    s.end();
}

// === Group ===

fun setup_group(s: &mut Scenario) {
    s.next_tx(ADMIN);
    let (admin_cap, rules_cap) = group::create(str(b""), s.ctx());
    transfer::public_transfer(admin_cap, ADMIN);
    transfer::public_transfer(rules_cap, ADMIN);
}

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
        token_gated_rule::add<JoinGroupOp, HANEUL>(&mut set, &cap, 500, true);
        s.return_to_sender(cap);
        ts::return_shared(set);
    };

    s.next_tx(ALICE);
    {
        let mut g = s.take_shared<Group>();
        let set = s.take_shared<RuleSet<JoinGroupOp>>();
        let holdings = coin::mint_for_testing<HANEUL>(600, s.ctx());
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
        token_gated_rule::add<JoinGroupOp, HANEUL>(&mut set, &cap, 500, true);
        s.return_to_sender(cap);
        ts::return_shared(set);
    };

    s.next_tx(ALICE);
    let mut g = s.take_shared<Group>();
    let set = s.take_shared<RuleSet<JoinGroupOp>>();
    let holdings = coin::mint_for_testing<HANEUL>(499, s.ctx());
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

// === Adversarial: rule system ===

/// Registers a payment-gated follow rule set for `account`.
fun setup_paid_follow(s: &mut Scenario, account: address, amount: u64) {
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
        simple_payment_rule::add<FollowOp, HANEUL>(&mut set, &cap, amount, account, true);
        s.return_to_sender(cap);
        ts::return_shared(set);
        ts::return_shared(g);
    };
}

#[test]
#[expected_failure(abort_code = 1, location = humming::simple_payment_rule)]
fun graph_double_pay_aborts() {
    let mut s = ts::begin(ADMIN);
    setup_graph(&mut s);
    let clock = new_clock(&mut s);
    setup_paid_follow(&mut s, BOB, 1000);

    // Paying the same rule set twice for one request must abort, not
    // silently take a second payment.
    s.next_tx(ALICE);
    let mut g = s.take_shared<Graph>();
    let graph_set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, graph::graph_rules_id(&g));
    let bob_set_id = graph::follow_rules_of(&g, BOB).destroy_some();
    let bob_set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, bob_set_id);
    let mut payment = coin::mint_for_testing<HANEUL>(3000, s.ctx());
    let (ticket, mut req) = graph::request_follow(&g, BOB, s.ctx());
    simple_payment_rule::pay(&bob_set, &mut req, &mut payment, s.ctx());
    simple_payment_rule::pay(&bob_set, &mut req, &mut payment, s.ctx());
    graph::execute_follow_gated(&mut g, &graph_set, &bob_set, ticket, req, &clock, s.ctx());
    payment.burn_for_testing();
    ts::return_shared(g);
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
    let clock = new_clock(&mut s);
    // Carol charges 10, Bob charges 1000.
    setup_paid_follow(&mut s, CAROL, 10);
    setup_paid_follow(&mut s, BOB, 1000);

    // Alice pays Carol's cheap fee, then tries to use that stamp to
    // follow Bob. The stamp is bound to Carol's rule set ID, so Bob's
    // required payment rule reads as unsatisfied.
    s.next_tx(ALICE);
    let mut g = s.take_shared<Graph>();
    let graph_set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, graph::graph_rules_id(&g));
    let carol_set_id = graph::follow_rules_of(&g, CAROL).destroy_some();
    let carol_set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, carol_set_id);
    let bob_set_id = graph::follow_rules_of(&g, BOB).destroy_some();
    let bob_set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, bob_set_id);
    let mut payment = coin::mint_for_testing<HANEUL>(10, s.ctx());
    let (ticket, mut req) = graph::request_follow(&g, BOB, s.ctx());
    simple_payment_rule::pay(&carol_set, &mut req, &mut payment, s.ctx());
    graph::execute_follow_gated(&mut g, &graph_set, &bob_set, ticket, req, &clock, s.ctx());
    payment.burn_for_testing();
    ts::return_shared(g);
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
        simple_payment_rule::remove<FollowOp, HANEUL>(&mut set, &cap);
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

// === Rule framework: any_of semantics & administration ===

/// Group whose join rule set has two ANY-OF rules: hold at least 500
/// GEUNHWA, or pay 1000. Satisfying either one admits.
fun setup_any_of_group(s: &mut Scenario) {
    setup_group(s);
    s.next_tx(ADMIN);
    let mut set = s.take_shared<RuleSet<JoinGroupOp>>();
    let cap = s.take_from_sender<RuleSetCap>();
    token_gated_rule::add<JoinGroupOp, HANEUL>(&mut set, &cap, 500, false);
    simple_payment_rule::add<JoinGroupOp, HANEUL>(&mut set, &cap, 1000, ADMIN, false);
    s.return_to_sender(cap);
    ts::return_shared(set);
}

#[test]
fun group_any_of_either_rule_admits() {
    let mut s = ts::begin(ADMIN);
    setup_any_of_group(&mut s);
    let clock = new_clock(&mut s);

    // Alice pays; she never proves the token rule.
    s.next_tx(ALICE);
    {
        let mut g = s.take_shared<Group>();
        let set = s.take_shared<RuleSet<JoinGroupOp>>();
        let mut payment = coin::mint_for_testing<HANEUL>(1000, s.ctx());
        let (ticket, mut req) = group::request_join(&g, s.ctx());
        simple_payment_rule::pay(&set, &mut req, &mut payment, s.ctx());
        group::execute_join(&mut g, &set, ticket, req, &clock);
        assert!(group::is_member(&g, ALICE));
        payment.destroy_zero();
        ts::return_shared(g);
        ts::return_shared(set);
    };

    // Bob shows a holding; he never pays.
    s.next_tx(BOB);
    {
        let mut g = s.take_shared<Group>();
        let set = s.take_shared<RuleSet<JoinGroupOp>>();
        let holdings = coin::mint_for_testing<HANEUL>(500, s.ctx());
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
        token_gated_rule::add<JoinGroupOp, HANEUL>(&mut set, &cap, 500, true);
        simple_payment_rule::add<JoinGroupOp, HANEUL>(&mut set, &cap, 1000, ADMIN, false);
        s.return_to_sender(cap);
        ts::return_shared(set);
    };

    // Alice proves the required token rule but never pays.
    s.next_tx(ALICE);
    let mut g = s.take_shared<Group>();
    let set = s.take_shared<RuleSet<JoinGroupOp>>();
    let holdings = coin::mint_for_testing<HANEUL>(600, s.ctx());
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
    let clock = new_clock(&mut s);

    s.next_tx(ADMIN);
    {
        let mut set = s.take_shared<RuleSet<JoinGroupOp>>();
        let cap = s.take_from_sender<RuleSetCap>();
        token_gated_rule::add<JoinGroupOp, HANEUL>(&mut set, &cap, 500, true);
        simple_payment_rule::add<JoinGroupOp, HANEUL>(&mut set, &cap, 1000, ADMIN, false);
        s.return_to_sender(cap);
        ts::return_shared(set);
    };

    // Alice pays (any-of) but never proves the required token rule.
    s.next_tx(ALICE);
    let mut g = s.take_shared<Group>();
    let set = s.take_shared<RuleSet<JoinGroupOp>>();
    let mut payment = coin::mint_for_testing<HANEUL>(1000, s.ctx());
    let (ticket, mut req) = group::request_join(&g, s.ctx());
    simple_payment_rule::pay(&set, &mut req, &mut payment, s.ctx());
    group::execute_join(&mut g, &set, ticket, req, &clock);
    payment.destroy_zero();
    ts::return_shared(g);
    ts::return_shared(set);
    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = 0, location = humming::rules)]
fun rules_duplicate_add_aborts() {
    let mut s = ts::begin(ADMIN);
    setup_group(&mut s);

    // Re-adding a rule must abort even under the other requiredness.
    s.next_tx(ADMIN);
    let mut set = s.take_shared<RuleSet<JoinGroupOp>>();
    let cap = s.take_from_sender<RuleSetCap>();
    token_gated_rule::add<JoinGroupOp, HANEUL>(&mut set, &cap, 500, true);
    token_gated_rule::add<JoinGroupOp, HANEUL>(&mut set, &cap, 900, false);
    s.return_to_sender(cap);
    ts::return_shared(set);
    s.end();
}

/// A `RuleSetCap` only administers the exact set it was created with —
/// here Bob tries to configure ALICE's follow rules with HIS own cap.
#[test]
#[expected_failure(abort_code = 5, location = humming::rules)]
fun rules_foreign_cap_rejected() {
    let mut s = ts::begin(ADMIN);
    setup_graph(&mut s);

    s.next_tx(ALICE);
    {
        let mut g = s.take_shared<Graph>();
        let cap = graph::create_my_follow_rules(&mut g, s.ctx());
        transfer::public_transfer(cap, ALICE);
        ts::return_shared(g);
    };
    s.next_tx(BOB);
    {
        let mut g = s.take_shared<Graph>();
        let cap = graph::create_my_follow_rules(&mut g, s.ctx());
        transfer::public_transfer(cap, BOB);
        ts::return_shared(g);
    };

    s.next_tx(BOB);
    let g = s.take_shared<Graph>();
    let alice_set_id = graph::follow_rules_of(&g, ALICE).destroy_some();
    let mut alice_set = ts::take_shared_by_id<RuleSet<FollowOp>>(&s, alice_set_id);
    let bob_cap = s.take_from_sender<RuleSetCap>();
    simple_payment_rule::add<FollowOp, HANEUL>(&mut alice_set, &bob_cap, 1, BOB, true);
    s.return_to_sender(bob_cap);
    ts::return_shared(alice_set);
    ts::return_shared(g);
    s.end();
}

/// Removing a rule that was never added aborts (the presence of a
/// different rule does not mask the lookup).
#[test]
#[expected_failure(abort_code = 1, location = humming::rules)]
fun rules_remove_missing_rule_aborts() {
    let mut s = ts::begin(ADMIN);
    setup_group(&mut s);

    s.next_tx(ADMIN);
    let mut set = s.take_shared<RuleSet<JoinGroupOp>>();
    let cap = s.take_from_sender<RuleSetCap>();
    simple_payment_rule::add<JoinGroupOp, HANEUL>(&mut set, &cap, 1000, ADMIN, true);
    token_gated_rule::remove<JoinGroupOp, HANEUL>(&mut set, &cap);
    s.return_to_sender(cap);
    ts::return_shared(set);
    s.end();
}

/// `MAX_RULES` (20) counts required and any-of rules together: 10 of
/// each fill the set, the 21st add aborts.
#[test]
#[expected_failure(abort_code = 4, location = humming::rules)]
fun rules_max_rules_enforced() {
    let mut s = ts::begin(ADMIN);
    setup_group(&mut s);

    s.next_tx(ADMIN);
    let mut set = s.take_shared<RuleSet<JoinGroupOp>>();
    let cap = s.take_from_sender<RuleSetCap>();
    rules::add(FillerRule<u8> {}, &mut set, &cap, true, true);
    rules::add(FillerRule<u16> {}, &mut set, &cap, true, true);
    rules::add(FillerRule<u32> {}, &mut set, &cap, true, true);
    rules::add(FillerRule<u64> {}, &mut set, &cap, true, true);
    rules::add(FillerRule<u128> {}, &mut set, &cap, true, true);
    rules::add(FillerRule<u256> {}, &mut set, &cap, true, true);
    rules::add(FillerRule<bool> {}, &mut set, &cap, true, true);
    rules::add(FillerRule<address> {}, &mut set, &cap, true, true);
    rules::add(FillerRule<ID> {}, &mut set, &cap, true, true);
    rules::add(FillerRule<String> {}, &mut set, &cap, true, true);
    rules::add(FillerRule<vector<u8>> {}, &mut set, &cap, true, false);
    rules::add(FillerRule<vector<u16>> {}, &mut set, &cap, true, false);
    rules::add(FillerRule<vector<u32>> {}, &mut set, &cap, true, false);
    rules::add(FillerRule<vector<u64>> {}, &mut set, &cap, true, false);
    rules::add(FillerRule<vector<u128>> {}, &mut set, &cap, true, false);
    rules::add(FillerRule<vector<u256>> {}, &mut set, &cap, true, false);
    rules::add(FillerRule<vector<bool>> {}, &mut set, &cap, true, false);
    rules::add(FillerRule<vector<address>> {}, &mut set, &cap, true, false);
    rules::add(FillerRule<vector<ID>> {}, &mut set, &cap, true, false);
    rules::add(FillerRule<vector<String>> {}, &mut set, &cap, true, false);
    // 21st rule: over the cap.
    rules::add(FillerRule<vector<vector<u8>>> {}, &mut set, &cap, true, false);
    s.return_to_sender(cap);
    ts::return_shared(set);
    s.end();
}

// === Namespace: ownership-transfer paths ===

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

// === Feed: deletion semantics ===

#[test]
fun feed_delete_clears_content() {
    let mut s = ts::begin(ADMIN);
    setup_feed(&mut s);
    let clock = new_clock(&mut s);

    let p1 = create_simple_post(&mut s, ALICE, b"ipfs://secret", &clock);

    s.next_tx(ALICE);
    {
        let mut f = s.take_shared<Feed>();
        feed::delete_post(&mut f, p1, s.ctx());
        let post = feed::post(&f, p1);
        assert!(feed::post_is_deleted(&post));
        assert!(feed::post_content_uri(&post).is_empty());
        ts::return_shared(f);
    };

    clock.destroy_for_testing();
    s.end();
}

// === Locked-token rule ===

const DAY_MS: u64 = 86_400_000;

fun setup_locked_group(s: &mut Scenario) {
    setup_group(s);
    s.next_tx(ADMIN);
    let mut set = s.take_shared<RuleSet<JoinGroupOp>>();
    let cap = s.take_from_sender<RuleSetCap>();
    locked_token_rule::add<JoinGroupOp, HANEUL>(&mut set, &cap, 500, DAY_MS, true);
    s.return_to_sender(cap);
    ts::return_shared(set);
}

#[test]
fun group_locked_token_join_and_withdraw_after_unlock() {
    let mut s = ts::begin(ADMIN);
    setup_locked_group(&mut s);
    let mut clock = new_clock(&mut s);

    // Alice locks 600, proves, and joins. The proof extends the lock.
    s.next_tx(ALICE);
    {
        let mut g = s.take_shared<Group>();
        let set = s.take_shared<RuleSet<JoinGroupOp>>();
        let mut lock = locked_token_rule::new_lock<HANEUL>(s.ctx());
        locked_token_rule::deposit(&mut lock, coin::mint_for_testing<HANEUL>(600, s.ctx()));
        let (ticket, mut req) = group::request_join(&g, s.ctx());
        locked_token_rule::prove(&set, &mut req, &mut lock, &clock);
        group::execute_join(&mut g, &set, ticket, req, &clock);
        assert!(group::is_member(&g, ALICE));
        assert!(locked_token_rule::locked_balance(&lock) == 600);
        assert!(locked_token_rule::unlock_ms(&lock) == DAY_MS);
        // Lock lifecycle events were emitted...
        assert!(event::events_by_type<locked_token_rule::LockCreated>().length() == 1);
        assert!(event::events_by_type<locked_token_rule::Deposited>().length() == 1);
        assert!(event::events_by_type<locked_token_rule::LockExtended>().length() == 1);
        // ...and a second proof at the same instant is silent: the
        // release time does not move, so no event is emitted.
        let mut req2 = rules::new_request<JoinGroupOp>(@0x0, ALICE);
        locked_token_rule::prove(&set, &mut req2, &mut lock, &clock);
        rules::destroy(req2);
        assert!(event::events_by_type<locked_token_rule::LockExtended>().length() == 1);
        locked_token_rule::keep(lock, s.ctx());
        ts::return_shared(g);
        ts::return_shared(set);
    };

    // After the lock period elapses, Alice withdraws everything.
    s.next_tx(ALICE);
    {
        clock.set_for_testing(DAY_MS);
        let mut lock = s.take_from_sender<Lock<HANEUL>>();
        let funds = locked_token_rule::withdraw(&mut lock, 600, &clock, s.ctx());
        assert!(funds.value() == 600);
        funds.burn_for_testing();
        locked_token_rule::destroy_empty(lock);
        assert!(event::events_by_type<locked_token_rule::Withdrawn>().length() == 1);
        assert!(event::events_by_type<locked_token_rule::LockDestroyed>().length() == 1);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = 1, location = humming::locked_token_rule)]
fun locked_token_withdraw_before_unlock_fails() {
    let mut s = ts::begin(ADMIN);
    setup_locked_group(&mut s);
    let clock = new_clock(&mut s);

    // Proving and withdrawing in the same breath must abort: this is
    // exactly the borrow-prove-return flash pattern the lock prevents.
    s.next_tx(ALICE);
    let mut g = s.take_shared<Group>();
    let set = s.take_shared<RuleSet<JoinGroupOp>>();
    let mut lock = locked_token_rule::new_lock<HANEUL>(s.ctx());
    locked_token_rule::deposit(&mut lock, coin::mint_for_testing<HANEUL>(600, s.ctx()));
    let (ticket, mut req) = group::request_join(&g, s.ctx());
    locked_token_rule::prove(&set, &mut req, &mut lock, &clock);
    let funds = locked_token_rule::withdraw(&mut lock, 600, &clock, s.ctx());
    funds.burn_for_testing();
    group::execute_join(&mut g, &set, ticket, req, &clock);
    locked_token_rule::keep(lock, s.ctx());
    ts::return_shared(g);
    ts::return_shared(set);
    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = 0, location = humming::locked_token_rule)]
fun locked_token_insufficient_locked_balance_fails() {
    let mut s = ts::begin(ADMIN);
    setup_locked_group(&mut s);
    let clock = new_clock(&mut s);

    s.next_tx(ALICE);
    let mut g = s.take_shared<Group>();
    let set = s.take_shared<RuleSet<JoinGroupOp>>();
    let mut lock = locked_token_rule::new_lock<HANEUL>(s.ctx());
    locked_token_rule::deposit(&mut lock, coin::mint_for_testing<HANEUL>(499, s.ctx()));
    let (ticket, mut req) = group::request_join(&g, s.ctx());
    locked_token_rule::prove(&set, &mut req, &mut lock, &clock);
    group::execute_join(&mut g, &set, ticket, req, &clock);
    locked_token_rule::keep(lock, s.ctx());
    ts::return_shared(g);
    ts::return_shared(set);
    clock.destroy_for_testing();
    s.end();
}

// === Package init: display & kiosk trading ===

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
        s.return_to_sender(publisher);
        s.return_to_sender(display);
        ts::return_shared(policy);
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

// === Profile ===

#[test]
fun profile_create_and_update() {
    let mut s = ts::begin(ALICE);
    let clock = new_clock(&mut s);
    profile::create(str(b"ipfs://alice-profile"), &clock, s.ctx());

    s.next_tx(ALICE);
    {
        let mut p = s.take_from_sender<Profile>();
        assert!(profile::metadata_uri(&p) == str(b"ipfs://alice-profile"));
        profile::set_metadata_uri(&mut p, str(b"ipfs://alice-v2"));
        assert!(profile::metadata_uri(&p) == str(b"ipfs://alice-v2"));
        s.return_to_sender(p);
    };

    clock.destroy_for_testing();
    s.end();
}

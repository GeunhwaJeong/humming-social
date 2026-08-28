// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Tests for `humming::feed`: posting semantics (reply/quote/repost),
/// editing, deletion, and per-post reply rules.
#[test_only]
module humming::feed_tests;

use humming::feed::{Self, CreatePostOp, Feed, InteractPostOp};
use humming::followers_only_rule;
use humming::graph::Graph;
use humming::rules::{RuleSet, RuleSetCap};
use humming::test_helpers::{str, new_clock, setup_graph, setup_feed, create_simple_post, follow};
use sui::test_scenario::{Self as ts};

const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;
const CAROL: address = @0xCA401;

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

// === Failure-path completion: repost semantics ===

#[test]
#[expected_failure(abort_code = 7, location = humming::feed)]
fun feed_repost_with_content_rejected() {
    let mut s = ts::begin(ADMIN);
    setup_feed(&mut s);
    let clock = new_clock(&mut s);

    let p1 = create_simple_post(&mut s, ALICE, b"ipfs://original", &clock);

    s.next_tx(BOB);
    let mut f = s.take_shared<Feed>();
    let set = ts::take_shared_by_id<RuleSet<CreatePostOp>>(&s, feed::feed_rules_id(&f));
    // A repost must not carry content of its own.
    let (ticket, req) = feed::request_create_post(
        &f,
        str(b"ipfs://smuggled-content"),
        option::none(),
        option::none(),
        option::some(p1),
        s.ctx(),
    );
    let _ = feed::execute_create_post(&mut f, &set, ticket, req, &clock);
    ts::return_shared(f);
    ts::return_shared(set);
    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = 8, location = humming::feed)]
fun feed_repost_cannot_reference() {
    let mut s = ts::begin(ADMIN);
    setup_feed(&mut s);
    let clock = new_clock(&mut s);

    let p1 = create_simple_post(&mut s, ALICE, b"ipfs://original", &clock);

    s.next_tx(BOB);
    let mut f = s.take_shared<Feed>();
    let set = ts::take_shared_by_id<RuleSet<CreatePostOp>>(&s, feed::feed_rules_id(&f));
    // A repost cannot simultaneously reply.
    let (ticket, req) = feed::request_create_post(
        &f,
        str(b""),
        option::some(p1),
        option::none(),
        option::some(p1),
        s.ctx(),
    );
    let _ = feed::execute_create_post(&mut f, &set, ticket, req, &clock);
    ts::return_shared(f);
    ts::return_shared(set);
    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = 9, location = humming::feed)]
fun feed_cannot_edit_repost() {
    let mut s = ts::begin(ADMIN);
    setup_feed(&mut s);
    let clock = new_clock(&mut s);

    let p1 = create_simple_post(&mut s, ALICE, b"ipfs://original", &clock);

    // Alice reposts her own post, then tries to edit the repost.
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
    feed::edit_post(&mut f, p2, str(b"ipfs://sneaky-edit"), &clock, s.ctx());
    ts::return_shared(f);
    ts::return_shared(set);
    clock.destroy_for_testing();
    s.end();
}

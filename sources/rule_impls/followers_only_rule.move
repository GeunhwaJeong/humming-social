// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Followers-only reply rule (Lens V3 `FollowersOnlyPostRule`).
///
/// Attached to a post's `RuleSet<InteractPostOp>`; only accounts that
/// follow the post's author on the configured graph may reply.
module humming::followers_only_rule;

use humming::feed::{Self, CreatePostTicket, InteractPostOp};
use humming::graph::{Self, Graph};
use humming::rules::{Self, Request, RuleSet, RuleSetCap};

const EWrongGraph: u64 = 0;
const ENotFollowing: u64 = 1;
const EKeyMismatch: u64 = 2;
const ENoParent: u64 = 3;

public struct FollowersOnlyRule has drop {}

public struct Config has store {
    graph: ID,
}

public fun add(set: &mut RuleSet<InteractPostOp>, cap: &RuleSetCap, graph: ID, required: bool) {
    rules::add(FollowersOnlyRule {}, set, cap, Config { graph }, required)
}

public fun remove(set: &mut RuleSet<InteractPostOp>, cap: &RuleSetCap) {
    let Config { graph: _ } = rules::remove<InteractPostOp, FollowersOnlyRule, Config>(set, cap);
}

/// Prove the replier follows the parent post's author on the
/// configured graph, and stamp the parent request.
public fun prove(
    set: &RuleSet<InteractPostOp>,
    ticket: &CreatePostTicket,
    req: &mut Request<InteractPostOp>,
    graph: &Graph,
) {
    let config = rules::config<InteractPostOp, FollowersOnlyRule, Config>(set);
    assert!(object::id(graph) == config.graph, EWrongGraph);
    assert!(feed::ticket_key(ticket) == rules::request_key(req), EKeyMismatch);
    let parent_author = feed::ticket_parent_author(ticket);
    assert!(parent_author.is_some(), ENoParent);
    assert!(
        graph::is_following(graph, rules::request_account(req), parent_author.destroy_some()),
        ENotFollowing,
    );
    rules::add_approval(FollowersOnlyRule {}, set, req);
}

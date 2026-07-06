// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Follow graph primitive (Lens V3 `Graph`).
///
/// Follows are gated by two layers of rules, exactly as in Lens V3:
/// - graph-level rules (`RuleSet<FollowOp>` created with the graph),
/// - optional per-account follow rules (each account may register its
///   own `RuleSet<FollowOp>`, e.g. paid follows).
///
/// A follow that targets an account with registered rules must go
/// through `execute_follow_gated`, passing the target's rule set.
module humming::graph;

use humming::rules::{Self, Request, RuleSet, RuleSetCap};
use std::string::String;
use haneul::clock::Clock;
use haneul::event;
use haneul::table::{Self, Table};

const ECannotFollowSelf: u64 = 0;
const EAlreadyFollowing: u64 = 1;
const ENotFollowing: u64 = 2;
const EWrongGraph: u64 = 3;
const EWrongRuleSet: u64 = 4;
const EKeyMismatch: u64 = 5;
const ETargetHasRules: u64 = 6;
const ETargetHasNoRules: u64 = 7;
const EWrongCap: u64 = 8;
const EAlreadyHasRuleSet: u64 = 9;
const ENoRuleSet: u64 = 10;

/// Operation marker: following an account.
public struct FollowOp {}

public struct Follow has drop, store {
    since_ms: u64,
}

public struct Graph has key {
    id: UID,
    metadata_uri: String,
    /// ID of the shared graph-level `RuleSet<FollowOp>`.
    graph_rules: ID,
    /// follower -> (target -> Follow)
    following: Table<address, Table<address, Follow>>,
    followers_count: Table<address, u64>,
    following_count: Table<address, u64>,
    /// Per-account follow rule sets (Lens V3 "follow rules").
    account_rules: Table<address, ID>,
}

public struct GraphAdminCap has key, store {
    id: UID,
    graph: ID,
}

/// Hot potato paired with a `Request<FollowOp>`.
public struct FollowTicket {
    graph: ID,
    key: address,
    follower: address,
    target: address,
}

public struct GraphCreated has copy, drop {
    graph: ID,
}

public struct Followed has copy, drop {
    graph: ID,
    follower: address,
    target: address,
}

public struct Unfollowed has copy, drop {
    graph: ID,
    follower: address,
    target: address,
}

public struct FollowRulesRegistered has copy, drop {
    graph: ID,
    account: address,
    set: ID,
}

public struct FollowRulesUnregistered has copy, drop {
    graph: ID,
    account: address,
}

public fun create(metadata_uri: String, ctx: &mut TxContext): (GraphAdminCap, RuleSetCap) {
    let (set, set_cap) = rules::new<FollowOp>(ctx);
    let graph = Graph {
        id: object::new(ctx),
        metadata_uri,
        graph_rules: object::id(&set),
        following: table::new(ctx),
        followers_count: table::new(ctx),
        following_count: table::new(ctx),
        account_rules: table::new(ctx),
    };
    let admin_cap = GraphAdminCap { id: object::new(ctx), graph: object::id(&graph) };
    event::emit(GraphCreated { graph: object::id(&graph) });
    transfer::public_share_object(set);
    transfer::share_object(graph);
    (admin_cap, set_cap)
}

// === Per-account follow rules ===

/// Create and register a follow rule set for the sender. Accounts that
/// want to gate follows on themselves (e.g. paid follows) call this
/// once, then configure rules on the shared set using the returned cap.
public fun create_my_follow_rules(graph: &mut Graph, ctx: &mut TxContext): RuleSetCap {
    let account = ctx.sender();
    assert!(!graph.account_rules.contains(account), EAlreadyHasRuleSet);
    let (set, set_cap) = rules::new<FollowOp>(ctx);
    graph.account_rules.add(account, object::id(&set));
    event::emit(FollowRulesRegistered {
        graph: object::id(graph),
        account,
        set: object::id(&set),
    });
    transfer::public_share_object(set);
    set_cap
}

/// Unregister the sender's follow rules. The shared rule set object
/// remains but is no longer consulted.
public fun remove_my_follow_rules(graph: &mut Graph, ctx: &TxContext) {
    let account = ctx.sender();
    assert!(graph.account_rules.contains(account), ENoRuleSet);
    graph.account_rules.remove(account);
    event::emit(FollowRulesUnregistered { graph: object::id(graph), account });
}

// === Follow (rule-gated) ===

public fun request_follow(
    graph: &Graph,
    target: address,
    ctx: &mut TxContext,
): (FollowTicket, Request<FollowOp>) {
    let follower = ctx.sender();
    assert!(follower != target, ECannotFollowSelf);
    assert!(!is_following(graph, follower, target), EAlreadyFollowing);
    let key = ctx.fresh_object_address();
    let ticket = FollowTicket { graph: object::id(graph), key, follower, target };
    (ticket, rules::new_request(key, follower))
}

/// Complete a follow whose target has NO registered follow rules.
public fun execute_follow(
    graph: &mut Graph,
    graph_rules: &RuleSet<FollowOp>,
    ticket: FollowTicket,
    req: Request<FollowOp>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let FollowTicket { graph: graph_id, key, follower, target } = ticket;
    assert!(graph_id == object::id(graph), EWrongGraph);
    assert!(object::id(graph_rules) == graph.graph_rules, EWrongRuleSet);
    assert!(key == rules::request_key(&req), EKeyMismatch);
    assert!(!graph.account_rules.contains(target), ETargetHasRules);
    rules::confirm(graph_rules, req);
    insert_follow(graph, follower, target, clock, ctx);
}

/// Complete a follow whose target HAS registered follow rules: the
/// request must additionally satisfy the target's rule set.
public fun execute_follow_gated(
    graph: &mut Graph,
    graph_rules: &RuleSet<FollowOp>,
    target_rules: &RuleSet<FollowOp>,
    ticket: FollowTicket,
    req: Request<FollowOp>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let FollowTicket { graph: graph_id, key, follower, target } = ticket;
    assert!(graph_id == object::id(graph), EWrongGraph);
    assert!(object::id(graph_rules) == graph.graph_rules, EWrongRuleSet);
    assert!(key == rules::request_key(&req), EKeyMismatch);
    assert!(graph.account_rules.contains(target), ETargetHasNoRules);
    assert!(*graph.account_rules.borrow(target) == object::id(target_rules), EWrongRuleSet);
    rules::check(graph_rules, &req);
    rules::check(target_rules, &req);
    rules::destroy(req);
    insert_follow(graph, follower, target, clock, ctx);
}

public fun unfollow(graph: &mut Graph, target: address, ctx: &TxContext) {
    let follower = ctx.sender();
    assert!(is_following(graph, follower, target), ENotFollowing);
    graph.following.borrow_mut(follower).remove(target);
    decrement(&mut graph.followers_count, target);
    decrement(&mut graph.following_count, follower);
    event::emit(Unfollowed { graph: object::id(graph), follower, target });
}

// === Admin ===

public fun set_metadata_uri(graph: &mut Graph, cap: &GraphAdminCap, metadata_uri: String) {
    assert!(cap.graph == object::id(graph), EWrongCap);
    graph.metadata_uri = metadata_uri;
}

// === Getters ===

public fun is_following(graph: &Graph, follower: address, target: address): bool {
    graph.following.contains(follower) && graph.following.borrow(follower).contains(target)
}

public fun followers_count_of(graph: &Graph, account: address): u64 {
    if (graph.followers_count.contains(account)) {
        *graph.followers_count.borrow(account)
    } else {
        0
    }
}

public fun following_count_of(graph: &Graph, account: address): u64 {
    if (graph.following_count.contains(account)) {
        *graph.following_count.borrow(account)
    } else {
        0
    }
}

public fun graph_rules_id(graph: &Graph): ID { graph.graph_rules }

public fun follow_rules_of(graph: &Graph, account: address): Option<ID> {
    if (graph.account_rules.contains(account)) {
        option::some(*graph.account_rules.borrow(account))
    } else {
        option::none()
    }
}

public fun ticket_key(ticket: &FollowTicket): address { ticket.key }

public fun ticket_follower(ticket: &FollowTicket): address { ticket.follower }

public fun ticket_target(ticket: &FollowTicket): address { ticket.target }

// === Internal ===

fun insert_follow(
    graph: &mut Graph,
    follower: address,
    target: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    if (!graph.following.contains(follower)) {
        graph.following.add(follower, table::new(ctx));
    };
    graph.following.borrow_mut(follower).add(target, Follow { since_ms: clock.timestamp_ms() });
    increment(&mut graph.followers_count, target);
    increment(&mut graph.following_count, follower);
    event::emit(Followed { graph: object::id(graph), follower, target });
}

fun increment(counts: &mut Table<address, u64>, account: address) {
    if (!counts.contains(account)) {
        counts.add(account, 0);
    };
    let count = counts.borrow_mut(account);
    *count = *count + 1;
}

fun decrement(counts: &mut Table<address, u64>, account: address) {
    let count = counts.borrow_mut(account);
    *count = *count - 1;
}

// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Feed primitive (Lens V3 `Feed`).
///
/// Posts live in a table keyed by a feed-local sequential id and carry
/// the same reference semantics as Lens V3: reply, quote, and repost,
/// with `root` tracking the thread root (replies and reposts inherit
/// the parent's root; quotes start their own thread, matching
/// `FeedCore._createPost`).
///
/// Two rule layers, as in Lens V3:
/// - feed-level rules on post creation (`RuleSet<CreatePostOp>`),
/// - optional per-post rules gating replies to that post
///   (`RuleSet<InteractPostOp>`, e.g. followers-only replies).
module humming::feed;

use humming::rules::{Self, Request, RuleSet, RuleSetCap};
use std::string::String;
use haneul::clock::Clock;
use haneul::event;
use haneul::table::{Self, Table};

const EPostNotFound: u64 = 0;
const ENotAuthor: u64 = 1;
const EWrongFeed: u64 = 2;
const EWrongRuleSet: u64 = 3;
const EKeyMismatch: u64 = 4;
const EParentGated: u64 = 5;
const EParentNotGated: u64 = 6;
const ERepostCannotHaveContent: u64 = 7;
const ERepostCannotReference: u64 = 8;
const ECannotEditRepost: u64 = 9;
const EPostAlreadyGated: u64 = 10;
const EWrongCap: u64 = 11;
const EWrongVersion: u64 = 12;
const EAlreadyCurrent: u64 = 13;
const EPostAlreadyPaywalled: u64 = 14;

/// Operation marker: creating a post on the feed.
public struct CreatePostOp {}

/// Operation marker: interacting with an existing post (replying).
public struct InteractPostOp {}

public struct Post has copy, drop, store {
    author: address,
    /// Feed-local sequential id (this is the post id).
    seq: u64,
    /// Sequential number among the author's posts on this feed.
    author_seq: u64,
    content_uri: String,
    /// Thread root post id.
    root: u64,
    replied_to: Option<u64>,
    quoted: Option<u64>,
    reposted: Option<u64>,
    created_ms: u64,
    updated_ms: u64,
    deleted: bool,
}

public struct Feed has key {
    id: UID,
    version: u64,
    metadata_uri: String,
    /// ID of the shared feed-level `RuleSet<CreatePostOp>`.
    feed_rules: ID,
    posts: Table<u64, Post>,
    post_count: u64,
    author_post_count: Table<address, u64>,
    /// Per-post reply rule sets: post id -> `RuleSet<InteractPostOp>` ID.
    post_rules: Table<u64, ID>,
    /// Per-post paywalls: post id -> `paid_posts::PostPaywall` ID.
    post_paywalls: Table<u64, ID>,
}

public struct FeedAdminCap has key, store {
    id: UID,
    feed: ID,
}

/// Hot potato paired with a `Request<CreatePostOp>` (and, when replying
/// to a rule-gated post, a `Request<InteractPostOp>`).
public struct CreatePostTicket {
    feed: ID,
    key: address,
    author: address,
    content_uri: String,
    replied_to: Option<u64>,
    quoted: Option<u64>,
    reposted: Option<u64>,
    parent_author: Option<address>,
    parent_gated: bool,
}

public struct FeedCreated has copy, drop {
    feed: ID,
}

public struct PostCreated has copy, drop {
    feed: ID,
    post_id: u64,
    author: address,
    content_uri: String,
    root: u64,
    replied_to: Option<u64>,
    quoted: Option<u64>,
    reposted: Option<u64>,
}

public struct PostEdited has copy, drop {
    feed: ID,
    post_id: u64,
    content_uri: String,
}

public struct PostDeleted has copy, drop {
    feed: ID,
    post_id: u64,
}

public struct PostRulesCreated has copy, drop {
    feed: ID,
    post_id: u64,
    set: ID,
}

public fun create(metadata_uri: String, ctx: &mut TxContext): (FeedAdminCap, RuleSetCap) {
    let (set, set_cap) = rules::new<CreatePostOp>(ctx);
    let feed = Feed {
        id: object::new(ctx),
        version: rules::current_version(),
        metadata_uri,
        feed_rules: object::id(&set),
        posts: table::new(ctx),
        post_count: 0,
        author_post_count: table::new(ctx),
        post_rules: table::new(ctx),
        post_paywalls: table::new(ctx),
    };
    let admin_cap = FeedAdminCap { id: object::new(ctx), feed: object::id(&feed) };
    event::emit(FeedCreated { feed: object::id(&feed) });
    transfer::public_share_object(set);
    transfer::share_object(feed);
    (admin_cap, set_cap)
}

// === Post creation (rule-gated) ===

public fun request_create_post(
    feed: &Feed,
    content_uri: String,
    replied_to: Option<u64>,
    quoted: Option<u64>,
    reposted: Option<u64>,
    ctx: &mut TxContext,
): (CreatePostTicket, Request<CreatePostOp>) {
    assert_version(feed);
    let author = ctx.sender();
    if (reposted.is_some()) {
        // Mirrors Lens V3: a repost carries no content of its own and
        // cannot simultaneously quote or reply.
        assert!(content_uri.is_empty(), ERepostCannotHaveContent);
        assert!(replied_to.is_none() && quoted.is_none(), ERepostCannotReference);
        assert_live_post(feed, *reposted.borrow());
    };
    if (quoted.is_some()) {
        assert_live_post(feed, *quoted.borrow());
    };
    let mut parent_author = option::none();
    let mut parent_gated = false;
    if (replied_to.is_some()) {
        let parent_id = *replied_to.borrow();
        assert_live_post(feed, parent_id);
        parent_author = option::some(feed.posts.borrow(parent_id).author);
        parent_gated = feed.post_rules.contains(parent_id);
    };
    let key = ctx.fresh_object_address();
    let ticket = CreatePostTicket {
        feed: object::id(feed),
        key,
        author,
        content_uri,
        replied_to,
        quoted,
        reposted,
        parent_author,
        parent_gated,
    };
    (ticket, rules::new_request(key, author))
}

/// Issue the additional request that must satisfy the parent post's
/// rules when replying to a rule-gated post.
public fun make_parent_request(ticket: &CreatePostTicket): Request<InteractPostOp> {
    assert!(ticket.parent_gated, EParentNotGated);
    rules::new_request(ticket.key, ticket.author)
}

/// Complete a post whose parent (if any) has NO reply rules.
public fun execute_create_post(
    feed: &mut Feed,
    feed_rules: &RuleSet<CreatePostOp>,
    ticket: CreatePostTicket,
    req: Request<CreatePostOp>,
    clock: &Clock,
): u64 {
    assert!(!ticket.parent_gated, EParentGated);
    check_common(feed, feed_rules, &ticket, rules::request_key(&req));
    rules::confirm(feed_rules, req);
    insert_post(feed, ticket, clock)
}

/// Complete a reply to a rule-gated post: the paired
/// `Request<InteractPostOp>` must satisfy the parent post's rule set.
public fun execute_create_post_gated(
    feed: &mut Feed,
    feed_rules: &RuleSet<CreatePostOp>,
    parent_rules: &RuleSet<InteractPostOp>,
    ticket: CreatePostTicket,
    req: Request<CreatePostOp>,
    parent_req: Request<InteractPostOp>,
    clock: &Clock,
): u64 {
    assert!(ticket.parent_gated, EParentNotGated);
    check_common(feed, feed_rules, &ticket, rules::request_key(&req));
    let parent_id = *ticket.replied_to.borrow();
    assert!(*feed.post_rules.borrow(parent_id) == object::id(parent_rules), EWrongRuleSet);
    assert!(rules::request_key(&parent_req) == ticket.key, EKeyMismatch);
    rules::confirm(feed_rules, req);
    rules::confirm(parent_rules, parent_req);
    insert_post(feed, ticket, clock)
}

// === Post management (author-only) ===

public fun edit_post(
    feed: &mut Feed,
    post_id: u64,
    content_uri: String,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert_version(feed);
    assert_live_post(feed, post_id);
    let post = feed.posts.borrow_mut(post_id);
    assert!(post.author == ctx.sender(), ENotAuthor);
    assert!(post.reposted.is_none(), ECannotEditRepost);
    post.content_uri = content_uri;
    post.updated_ms = clock.timestamp_ms();
    event::emit(PostEdited { feed: object::id(feed), post_id, content_uri });
}

public fun delete_post(feed: &mut Feed, post_id: u64, ctx: &TxContext) {
    assert_version(feed);
    assert_live_post(feed, post_id);
    let post = feed.posts.borrow_mut(post_id);
    assert!(post.author == ctx.sender(), ENotAuthor);
    post.deleted = true;
    // Clear the content pointer: "deleted" should not keep the content
    // discoverable on-chain (and the freed bytes earn a storage rebate).
    post.content_uri = b"".to_string();
    event::emit(PostDeleted { feed: object::id(feed), post_id });
}

/// Gate replies to one of your posts: creates and registers the post's
/// reply rule set, returning the cap to configure it.
public fun create_post_rules(feed: &mut Feed, post_id: u64, ctx: &mut TxContext): RuleSetCap {
    assert_version(feed);
    assert_live_post(feed, post_id);
    assert!(feed.posts.borrow(post_id).author == ctx.sender(), ENotAuthor);
    assert!(!feed.post_rules.contains(post_id), EPostAlreadyGated);
    let (set, set_cap) = rules::new<InteractPostOp>(ctx);
    feed.post_rules.add(post_id, object::id(&set));
    event::emit(PostRulesCreated { feed: object::id(feed), post_id, set: object::id(&set) });
    transfer::public_share_object(set);
    set_cap
}

// === Admin ===

public fun set_metadata_uri(feed: &mut Feed, cap: &FeedAdminCap, metadata_uri: String) {
    assert_version(feed);
    assert!(cap.feed == object::id(feed), EWrongCap);
    feed.metadata_uri = metadata_uri;
}

/// Bring a feed created under an older package version up to the
/// current one, re-enabling its entry points after an upgrade.
public fun migrate(feed: &mut Feed, cap: &FeedAdminCap) {
    assert!(cap.feed == object::id(feed), EWrongCap);
    assert!(feed.version < rules::current_version(), EAlreadyCurrent);
    feed.version = rules::current_version();
}

// === Getters ===

public fun post_exists(feed: &Feed, post_id: u64): bool {
    feed.posts.contains(post_id) && !feed.posts.borrow(post_id).deleted
}

public fun post(feed: &Feed, post_id: u64): Post {
    assert!(feed.posts.contains(post_id), EPostNotFound);
    *feed.posts.borrow(post_id)
}

public fun post_count(feed: &Feed): u64 { feed.post_count }

public fun feed_rules_id(feed: &Feed): ID { feed.feed_rules }

public fun version(feed: &Feed): u64 { feed.version }

public fun post_rules_of(feed: &Feed, post_id: u64): Option<ID> {
    if (feed.post_rules.contains(post_id)) {
        option::some(*feed.post_rules.borrow(post_id))
    } else {
        option::none()
    }
}

public fun paywall_of(feed: &Feed, post_id: u64): Option<ID> {
    if (feed.post_paywalls.contains(post_id)) {
        option::some(*feed.post_paywalls.borrow(post_id))
    } else {
        option::none()
    }
}

public fun post_author(post: &Post): address { post.author }

public fun post_content_uri(post: &Post): String { post.content_uri }

public fun post_root(post: &Post): u64 { post.root }

public fun post_replied_to(post: &Post): Option<u64> { post.replied_to }

public fun post_quoted(post: &Post): Option<u64> { post.quoted }

public fun post_reposted(post: &Post): Option<u64> { post.reposted }

public fun post_author_seq(post: &Post): u64 { post.author_seq }

public fun post_is_deleted(post: &Post): bool { post.deleted }

public fun ticket_key(ticket: &CreatePostTicket): address { ticket.key }

public fun ticket_author(ticket: &CreatePostTicket): address { ticket.author }

public fun ticket_parent_author(ticket: &CreatePostTicket): Option<address> {
    ticket.parent_author
}

public fun ticket_parent_gated(ticket: &CreatePostTicket): bool { ticket.parent_gated }

// === Package-internal (called by `paid_posts`) ===

/// Record a post's paywall. Authorship and post liveness are checked
/// by the caller; this enforces the one-paywall-per-post invariant.
public(package) fun register_paywall(feed: &mut Feed, post_id: u64, paywall: ID) {
    assert_version(feed);
    assert!(!feed.post_paywalls.contains(post_id), EPostAlreadyPaywalled);
    feed.post_paywalls.add(post_id, paywall);
}

// === Internal ===

fun check_common(
    feed: &Feed,
    feed_rules: &RuleSet<CreatePostOp>,
    ticket: &CreatePostTicket,
    req_key: address,
) {
    assert_version(feed);
    assert!(ticket.feed == object::id(feed), EWrongFeed);
    assert!(object::id(feed_rules) == feed.feed_rules, EWrongRuleSet);
    assert!(ticket.key == req_key, EKeyMismatch);
}

fun assert_live_post(feed: &Feed, post_id: u64) {
    assert!(post_exists(feed, post_id), EPostNotFound);
}

fun assert_version(feed: &Feed) {
    assert!(feed.version == rules::current_version(), EWrongVersion);
}

#[test_only]
public fun set_version_for_testing(feed: &mut Feed, version: u64) {
    feed.version = version;
}

fun insert_post(feed: &mut Feed, ticket: CreatePostTicket, clock: &Clock): u64 {
    let CreatePostTicket {
        feed: _,
        key: _,
        author,
        content_uri,
        replied_to,
        quoted,
        reposted,
        parent_author: _,
        parent_gated: _,
    } = ticket;
    let seq = feed.post_count + 1;
    feed.post_count = seq;
    if (!feed.author_post_count.contains(author)) {
        feed.author_post_count.add(author, 0);
    };
    let author_count = feed.author_post_count.borrow_mut(author);
    *author_count = *author_count + 1;
    let author_seq = *author_count;
    // Replies and reposts join the parent's thread; quotes start their
    // own (mirrors Lens V3 FeedCore).
    let mut root = seq;
    if (replied_to.is_some()) {
        root = feed.posts.borrow(*replied_to.borrow()).root;
    };
    if (reposted.is_some()) {
        root = feed.posts.borrow(*reposted.borrow()).root;
    };
    let now = clock.timestamp_ms();
    feed.posts.add(seq, Post {
        author,
        seq,
        author_seq,
        content_uri,
        root,
        replied_to,
        quoted,
        reposted,
        created_ms: now,
        updated_ms: now,
        deleted: false,
    });
    event::emit(PostCreated {
        feed: object::id(feed),
        post_id: seq,
        author,
        content_uri,
        root,
        replied_to,
        quoted,
        reposted,
    });
    seq
}

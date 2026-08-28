// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Per-post paywall — pay once to unlock a single post.
///
/// Content on an object chain is not secret (`content_uri` is public
/// state), so a paywall cannot withhold bytes. What it provides is the
/// canonical, creator-priced *purchase record*: the app serves full
/// content only to buyers, checked via `has_purchased` or the
/// `PostPurchased` event stream — the same division of labor as the
/// rest of the package (chain = rights ledger, app = enforcement).
///
/// One `PostPaywall<T>` per post, registered in the post's `Feed` so a
/// post can never carry two competing paywalls. The paywall is its own
/// shared object so purchases of different posts never contend.
/// Payments run through `humming::platform`.
module humming::paid_posts;

use humming::feed::{Self, Feed};
use humming::platform::{Self, FeeConfig};
use humming::rules;
use std::string::String;
use sui::coin::Coin;
use sui::event;
use sui::table::{Self, Table};

const ENotAuthor: u64 = 0;
const EPostNotFound: u64 = 1;
const EWrongFeed: u64 = 2;
const EPaywallClosed: u64 = 3;
const EAlreadyPurchased: u64 = 4;
const EAuthorCannotBuy: u64 = 5;
const EInvalidPrice: u64 = 6;
const ECannotPaywallRepost: u64 = 7;
const EWrongVersion: u64 = 8;
const EAlreadyCurrent: u64 = 9;
const EPriceMismatch: u64 = 10;

public struct PostPaywall<phantom T> has key {
    id: UID,
    version: u64,
    feed: ID,
    post_id: u64,
    /// The post's author at paywall creation: the paywall's admin
    /// authority (immutable).
    author: address,
    /// Proceeds recipient (initially the author). Kept separate from
    /// `author` so a creator can rotate payout wallets without losing
    /// the paywall's admin identity.
    recipient: address,
    price: u64,
    /// Closed paywalls reject new purchases; past purchases stand.
    active: bool,
    /// buyer -> price paid.
    purchases: Table<address, u64>,
    purchase_count: u64,
}

public struct PaywallCreated has copy, drop {
    paywall: ID,
    feed: ID,
    post_id: u64,
    price: u64,
}

public struct PostPurchased has copy, drop {
    paywall: ID,
    feed: ID,
    post_id: u64,
    buyer: address,
    amount: u64,
    fee: u64,
    /// The post's content pointer at purchase time. The author remains
    /// free to edit the post afterwards; this snapshot is the buyer's
    /// on-chain evidence of what was sold, and what the app should
    /// keep serving to this buyer in a dispute.
    content_uri: String,
}

public struct PaywallPriceChanged has copy, drop {
    paywall: ID,
    price: u64,
}

public struct PaywallActiveChanged has copy, drop {
    paywall: ID,
    active: bool,
}

public struct PaywallRecipientChanged has copy, drop {
    paywall: ID,
    recipient: address,
}

/// Paywall one of your posts. Registers the paywall in the feed (a
/// post can only ever have one) and shares it.
public fun create<T>(feed: &mut Feed, post_id: u64, price: u64, ctx: &mut TxContext) {
    assert!(price > 0, EInvalidPrice);
    assert!(feed::post_exists(feed, post_id), EPostNotFound);
    let post = feed::post(feed, post_id);
    assert!(feed::post_author(&post) == ctx.sender(), ENotAuthor);
    // A repost has no content of its own to sell.
    assert!(feed::post_reposted(&post).is_none(), ECannotPaywallRepost);
    let paywall = PostPaywall<T> {
        id: object::new(ctx),
        version: rules::current_version(),
        feed: object::id(feed),
        post_id,
        author: ctx.sender(),
        recipient: ctx.sender(),
        price,
        active: true,
        purchases: table::new(ctx),
        purchase_count: 0,
    };
    feed::register_paywall(feed, post_id, object::id(&paywall));
    event::emit(PaywallCreated {
        paywall: object::id(&paywall),
        feed: object::id(feed),
        post_id,
        price,
    });
    transfer::share_object(paywall);
}

/// Buy the post once. Proceeds (minus the platform's cut) go straight
/// to the paywall's recipient; the purchase is recorded permanently.
///
/// `expected_price` is the price the buyer saw when signing: if the
/// author's price change lands first, the purchase aborts instead of
/// silently charging the new price.
public fun purchase<T>(
    paywall: &mut PostPaywall<T>,
    fee_config: &FeeConfig,
    feed: &Feed,
    expected_price: u64,
    payment: &mut Coin<T>,
    ctx: &mut TxContext,
) {
    assert_version(paywall);
    assert!(paywall.feed == object::id(feed), EWrongFeed);
    assert!(paywall.active, EPaywallClosed);
    assert!(paywall.price == expected_price, EPriceMismatch);
    // A deleted post stops selling (its content pointer is cleared).
    assert!(feed::post_exists(feed, paywall.post_id), EPostNotFound);
    let buyer = ctx.sender();
    assert!(buyer != paywall.author, EAuthorCannotBuy);
    assert!(!paywall.purchases.contains(buyer), EAlreadyPurchased);
    let fee = platform::collect(fee_config, payment, paywall.price, paywall.recipient, ctx);
    paywall.purchases.add(buyer, paywall.price);
    paywall.purchase_count = paywall.purchase_count + 1;
    event::emit(PostPurchased {
        paywall: object::id(paywall),
        feed: paywall.feed,
        post_id: paywall.post_id,
        buyer,
        amount: paywall.price,
        fee,
        content_uri: feed::post_content_uri(&feed::post(feed, paywall.post_id)),
    });
}

#[test_only]
public fun purchase_event_content_uri(e: &PostPurchased): String {
    e.content_uri
}

// === Administration (author-gated) ===

public fun set_price<T>(paywall: &mut PostPaywall<T>, price: u64, ctx: &TxContext) {
    assert_version(paywall);
    assert_author(paywall, ctx);
    assert!(price > 0, EInvalidPrice);
    paywall.price = price;
    event::emit(PaywallPriceChanged { paywall: object::id(paywall), price });
}

public fun set_active<T>(paywall: &mut PostPaywall<T>, active: bool, ctx: &TxContext) {
    assert_version(paywall);
    assert_author(paywall, ctx);
    paywall.active = active;
    event::emit(PaywallActiveChanged { paywall: object::id(paywall), active });
}

/// Redirect future proceeds (wallet rotation). Admin authority stays
/// with `author`; only the payout target moves.
public fun set_recipient<T>(paywall: &mut PostPaywall<T>, recipient: address, ctx: &TxContext) {
    assert_version(paywall);
    assert_author(paywall, ctx);
    paywall.recipient = recipient;
    event::emit(PaywallRecipientChanged { paywall: object::id(paywall), recipient });
}

/// Bring a paywall created under an older package version up to the
/// current one, re-enabling its entry points after an upgrade.
public fun migrate<T>(paywall: &mut PostPaywall<T>, ctx: &TxContext) {
    assert_author(paywall, ctx);
    assert!(paywall.version < rules::current_version(), EAlreadyCurrent);
    paywall.version = rules::current_version();
}

// === Getters ===

public fun has_purchased<T>(paywall: &PostPaywall<T>, account: address): bool {
    paywall.purchases.contains(account)
}

public fun price<T>(paywall: &PostPaywall<T>): u64 { paywall.price }

public fun author<T>(paywall: &PostPaywall<T>): address { paywall.author }

public fun recipient<T>(paywall: &PostPaywall<T>): address { paywall.recipient }

public fun post_id<T>(paywall: &PostPaywall<T>): u64 { paywall.post_id }

public fun is_open<T>(paywall: &PostPaywall<T>): bool { paywall.active }

public fun purchase_count<T>(paywall: &PostPaywall<T>): u64 { paywall.purchase_count }

public fun version<T>(paywall: &PostPaywall<T>): u64 { paywall.version }

// === Internal ===

fun assert_author<T>(paywall: &PostPaywall<T>, ctx: &TxContext) {
    assert!(paywall.author == ctx.sender(), ENotAuthor);
}

fun assert_version<T>(paywall: &PostPaywall<T>) {
    assert!(paywall.version == rules::current_version(), EWrongVersion);
}

#[test_only]
public fun set_version_for_testing<T>(paywall: &mut PostPaywall<T>, version: u64) {
    paywall.version = version;
}

// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Tips — spontaneous payments to a creator, with an indexable trail.
///
/// Money already *could* flow through `platform::collect` directly, but
/// a bare `collect` leaves no domain event: indexers see only balance
/// changes and cannot aggregate "tips received by this post" or build
/// leaderboards. This module is the thin event-emitting wrapper that
/// makes tips first-class.
///
/// Two entry points:
/// - `tip`: a profile-level tip to an address the sender chose.
/// - `tip_post`: a tip attributed to a post. The recipient is derived
///   from the post's on-chain author — the client cannot mispair a
///   post with someone else's payout address, and the attribution in
///   the event is guaranteed to reference a post that existed at tip
///   time.
///
/// The module is stateless (nothing to migrate, no version gate); the
/// platform cut is applied by `platform::collect`, keeping every
/// monetization path behind the protocol's single fee lever.
module humming::tips;

use sui::coin::Coin;
use sui::event;
use humming::feed::{Self, Feed};
use humming::platform::{Self, FeeConfig};

const EInvalidAmount: u64 = 0;
const ESelfTip: u64 = 1;
const EPostNotFound: u64 = 2;

public struct TipSent has copy, drop {
    from: address,
    to: address,
    /// Gross amount the sender paid (fee included).
    amount: u64,
    /// The platform's cut, already forwarded to the treasury.
    fee: u64,
    /// The post this tip is attributed to, if any.
    post_id: Option<u64>,
}

/// Tip `to` directly (profile-level tip).
public fun tip<T>(
    config: &FeeConfig,
    to: address,
    amount: u64,
    payment: &mut Coin<T>,
    ctx: &mut TxContext,
) {
    send(config, to, amount, option::none(), payment, ctx)
}

/// Tip the author of `post_id`. The recipient comes from the feed, not
/// the caller, so the attribution and the payout can never disagree.
public fun tip_post<T>(
    config: &FeeConfig,
    feed: &Feed,
    post_id: u64,
    amount: u64,
    payment: &mut Coin<T>,
    ctx: &mut TxContext,
) {
    assert!(feed::post_exists(feed, post_id), EPostNotFound);
    let post = feed::post(feed, post_id);
    send(config, feed::post_author(&post), amount, option::some(post_id), payment, ctx)
}

fun send<T>(
    config: &FeeConfig,
    to: address,
    amount: u64,
    post_id: Option<u64>,
    payment: &mut Coin<T>,
    ctx: &mut TxContext,
) {
    assert!(amount > 0, EInvalidAmount);
    let from = ctx.sender();
    assert!(from != to, ESelfTip);
    let fee = platform::collect(config, payment, amount, to, ctx);
    event::emit(TipSent { from, to, amount, fee, post_id });
}

// === Test hooks ===

#[test_only]
public fun tip_event_to(e: &TipSent): address { e.to }

#[test_only]
public fun tip_event_amount(e: &TipSent): u64 { e.amount }

#[test_only]
public fun tip_event_fee(e: &TipSent): u64 { e.fee }

#[test_only]
public fun tip_event_post_id(e: &TipSent): Option<u64> { e.post_id }

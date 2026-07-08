// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Recurring, prepaid subscriptions — the Patreon primitive.
///
/// A `Tier<T>` is a creator's subscription offer priced in `T`:
/// `price` buys `period_ms` of access, and paying again *extends* the
/// current expiry, so renewals stack. Nothing recurs on-chain by
/// itself — an object chain has no pull payments — so a
/// "subscription" is exactly this: a prepaid, extendable expiry that
/// lets a backend answer "does this account currently have access?"
/// (`is_active_subscriber`), and lets `subscriber_only_rule` gate
/// on-chain interactions on the same question.
///
/// Payments run through `humming::platform`, so the platform's cut is
/// taken here like everywhere else. A lapsed subscription needs no
/// cleanup: expiry is a timestamp comparison, and re-subscribing
/// after a lapse starts from *now*, not from the stale expiry.
module humming::subscriptions;

use humming::platform::{Self, FeeConfig};
use humming::rules;
use std::string::String;
use haneul::clock::Clock;
use haneul::coin::Coin;
use haneul::event;
use haneul::table::{Self, Table};

const ETierClosed: u64 = 0;
const EWrongCap: u64 = 1;
const EInvalidConfig: u64 = 2;
const EWrongVersion: u64 = 3;
const EAlreadyCurrent: u64 = 4;
const EPriceMismatch: u64 = 5;

public struct Tier<phantom T> has key {
    id: UID,
    version: u64,
    /// Proceeds recipient (initially the creator).
    recipient: address,
    metadata_uri: String,
    /// Price of one period. Changing it affects future renewals only.
    price: u64,
    period_ms: u64,
    /// Closed tiers reject new subscriptions and renewals; existing
    /// prepaid time keeps running out on its own.
    active: bool,
    /// subscriber -> expiry timestamp (ms). Entries are never removed;
    /// an expired entry is just a timestamp in the past.
    subs: Table<address, u64>,
    /// Accounts that have ever subscribed.
    subscriber_count: u64,
}

public struct TierCap has key, store {
    id: UID,
    tier: ID,
}

public struct TierCreated has copy, drop {
    tier: ID,
    creator: address,
    price: u64,
    period_ms: u64,
}

/// Carries the new expiry — the one question a wallet needs answered
/// ("when does my subscription lapse?") without polling the object.
public struct Subscribed has copy, drop {
    tier: ID,
    subscriber: address,
    /// Who paid (gift subscriptions: payer != subscriber).
    payer: address,
    amount: u64,
    fee: u64,
    expires_ms: u64,
}

public struct TierPriceChanged has copy, drop {
    tier: ID,
    price: u64,
}

public struct TierActiveChanged has copy, drop {
    tier: ID,
    active: bool,
}

/// Create a subscription tier. Shares the tier; the cap administers
/// price, metadata, recipient, and open/closed state.
public fun create<T>(
    price: u64,
    period_ms: u64,
    metadata_uri: String,
    ctx: &mut TxContext,
): TierCap {
    assert!(price > 0 && period_ms > 0, EInvalidConfig);
    let tier = Tier<T> {
        id: object::new(ctx),
        version: rules::current_version(),
        recipient: ctx.sender(),
        metadata_uri,
        price,
        period_ms,
        active: true,
        subs: table::new(ctx),
        subscriber_count: 0,
    };
    let cap = TierCap { id: object::new(ctx), tier: object::id(&tier) };
    event::emit(TierCreated {
        tier: object::id(&tier),
        creator: ctx.sender(),
        price,
        period_ms,
    });
    transfer::share_object(tier);
    cap
}

/// Pay for one period for `beneficiary` (usually the sender; anyone
/// may gift). An active subscription is extended from its expiry; a
/// lapsed or new one starts from now.
///
/// `expected_price` is the price the payer saw when signing: if the
/// creator's price change lands first, the purchase aborts instead of
/// silently charging the new price.
public fun subscribe<T>(
    tier: &mut Tier<T>,
    fee_config: &FeeConfig,
    beneficiary: address,
    expected_price: u64,
    payment: &mut Coin<T>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_version(tier);
    assert!(tier.active, ETierClosed);
    assert!(tier.price == expected_price, EPriceMismatch);
    let fee = platform::collect(fee_config, payment, tier.price, tier.recipient, ctx);
    let now = clock.timestamp_ms();
    let expires_ms = if (tier.subs.contains(beneficiary)) {
        let current = tier.subs.remove(beneficiary);
        (if (current > now) current else now) + tier.period_ms
    } else {
        tier.subscriber_count = tier.subscriber_count + 1;
        now + tier.period_ms
    };
    tier.subs.add(beneficiary, expires_ms);
    event::emit(Subscribed {
        tier: object::id(tier),
        subscriber: beneficiary,
        payer: ctx.sender(),
        amount: tier.price,
        fee,
        expires_ms,
    });
}

// === Administration (cap-gated) ===

public fun set_price<T>(tier: &mut Tier<T>, cap: &TierCap, price: u64) {
    assert_version(tier);
    assert_cap(tier, cap);
    assert!(price > 0, EInvalidConfig);
    tier.price = price;
    event::emit(TierPriceChanged { tier: object::id(tier), price });
}

public fun set_metadata_uri<T>(tier: &mut Tier<T>, cap: &TierCap, metadata_uri: String) {
    assert_version(tier);
    assert_cap(tier, cap);
    tier.metadata_uri = metadata_uri;
}

public fun set_recipient<T>(tier: &mut Tier<T>, cap: &TierCap, recipient: address) {
    assert_version(tier);
    assert_cap(tier, cap);
    tier.recipient = recipient;
}

public fun set_active<T>(tier: &mut Tier<T>, cap: &TierCap, active: bool) {
    assert_version(tier);
    assert_cap(tier, cap);
    tier.active = active;
    event::emit(TierActiveChanged { tier: object::id(tier), active });
}

/// Bring a tier created under an older package version up to the
/// current one, re-enabling its entry points after an upgrade.
public fun migrate<T>(tier: &mut Tier<T>, cap: &TierCap) {
    assert_cap(tier, cap);
    assert!(tier.version < rules::current_version(), EAlreadyCurrent);
    tier.version = rules::current_version();
}

// === Getters ===

public fun is_active_subscriber<T>(tier: &Tier<T>, account: address, clock: &Clock): bool {
    tier.subs.contains(account) && *tier.subs.borrow(account) > clock.timestamp_ms()
}

public fun expires_ms<T>(tier: &Tier<T>, account: address): Option<u64> {
    if (tier.subs.contains(account)) {
        option::some(*tier.subs.borrow(account))
    } else {
        option::none()
    }
}

public fun price<T>(tier: &Tier<T>): u64 { tier.price }

public fun period_ms<T>(tier: &Tier<T>): u64 { tier.period_ms }

public fun recipient<T>(tier: &Tier<T>): address { tier.recipient }

public fun is_open<T>(tier: &Tier<T>): bool { tier.active }

public fun subscriber_count<T>(tier: &Tier<T>): u64 { tier.subscriber_count }

public fun version<T>(tier: &Tier<T>): u64 { tier.version }

// === Internal ===

fun assert_cap<T>(tier: &Tier<T>, cap: &TierCap) {
    assert!(cap.tier == object::id(tier), EWrongCap);
}

fun assert_version<T>(tier: &Tier<T>) {
    assert!(tier.version == rules::current_version(), EWrongVersion);
}

#[test_only]
public fun set_version_for_testing<T>(tier: &mut Tier<T>, version: u64) {
    tier.version = version;
}

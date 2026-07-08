// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Platform fee configuration — the protocol's single fee lever.
///
/// Every monetization path in the package (payment rules,
/// subscriptions, post paywalls) routes funds through `collect`, which
/// splits the platform's cut off the gross and forwards the remainder
/// to the creator. Three design goals:
///
/// - **One canonical config.** `new` is package-internal and called
///   exactly once, from the package initializer, so a `&FeeConfig`
///   parameter can only ever be satisfied by that one object — a
///   creator cannot wire a zero-fee lookalike into a payment path.
/// - **A ceiling, not a promise.** `MAX_FEE_BPS` is a compile-time
///   constant: no cap holder — not the platform, not a future
///   governance — can push the fee above it. Creators price against a
///   bounded worst case instead of trusting an announcement.
/// - **Governance-ready.** The fee changes only through
///   `FeeConfigCap`, an ordinary transferable object. Handing the fee
///   lever to a governance contract later is a transfer, not an
///   upgrade.
module humming::platform;

use humming::rules;
use haneul::coin::Coin;
use haneul::event;

const EFeeTooHigh: u64 = 0;
const EWrongCap: u64 = 1;
const EInsufficientPayment: u64 = 2;
const EWrongVersion: u64 = 3;
const EAlreadyCurrent: u64 = 4;

/// Hard ceiling on the platform fee: 10%.
const MAX_FEE_BPS: u64 = 1_000;
const BPS_DENOMINATOR: u64 = 10_000;

public struct FeeConfig has key {
    id: UID,
    version: u64,
    /// Platform cut in basis points (100 = 1%).
    fee_bps: u64,
    /// Where the platform's cut is sent.
    treasury: address,
}

/// Capability to change the fee (within `MAX_FEE_BPS`) and the
/// treasury address. Transferable — the intended endgame is handing it
/// to a governance contract.
public struct FeeConfigCap has key, store {
    id: UID,
    config: ID,
}

public struct FeeConfigCreated has copy, drop {
    config: ID,
    fee_bps: u64,
    treasury: address,
}

public struct FeeChanged has copy, drop {
    config: ID,
    fee_bps: u64,
}

public struct TreasuryChanged has copy, drop {
    config: ID,
    treasury: address,
}

/// Create and share the canonical fee config. Package-internal: only
/// the package initializer calls this, exactly once.
public(package) fun new(fee_bps: u64, treasury: address, ctx: &mut TxContext): FeeConfigCap {
    assert!(fee_bps <= MAX_FEE_BPS, EFeeTooHigh);
    let config = FeeConfig {
        id: object::new(ctx),
        version: rules::current_version(),
        fee_bps,
        treasury,
    };
    let cap = FeeConfigCap { id: object::new(ctx), config: object::id(&config) };
    event::emit(FeeConfigCreated { config: object::id(&config), fee_bps, treasury });
    transfer::share_object(config);
    cap
}

/// Split `amount` off `payment`: the platform's cut goes to the
/// treasury, the remainder to `recipient`. Returns the fee taken so
/// callers can put it in their domain events. The fee is floored, so
/// rounding always favors the creator.
public fun collect<T>(
    config: &FeeConfig,
    payment: &mut Coin<T>,
    amount: u64,
    recipient: address,
    ctx: &mut TxContext,
): u64 {
    if (amount == 0) return 0;
    assert!(payment.value() >= amount, EInsufficientPayment);
    // u128 intermediate: amount * fee_bps can overflow u64 for large
    // amounts (well within the coin supply).
    let fee =
        ((amount as u128) * (config.fee_bps as u128) / (BPS_DENOMINATOR as u128)) as u64;
    if (fee > 0) {
        transfer::public_transfer(payment.split(fee, ctx), config.treasury);
    };
    transfer::public_transfer(payment.split(amount - fee, ctx), recipient);
    fee
}

// === Administration (cap-gated) ===

public fun set_fee_bps(config: &mut FeeConfig, cap: &FeeConfigCap, fee_bps: u64) {
    assert_version(config);
    assert!(cap.config == object::id(config), EWrongCap);
    assert!(fee_bps <= MAX_FEE_BPS, EFeeTooHigh);
    config.fee_bps = fee_bps;
    event::emit(FeeChanged { config: object::id(config), fee_bps });
}

public fun set_treasury(config: &mut FeeConfig, cap: &FeeConfigCap, treasury: address) {
    assert_version(config);
    assert!(cap.config == object::id(config), EWrongCap);
    config.treasury = treasury;
    event::emit(TreasuryChanged { config: object::id(config), treasury });
}

/// Bring a fee config created under an older package version up to
/// the current one.
public fun migrate(config: &mut FeeConfig, cap: &FeeConfigCap) {
    assert!(cap.config == object::id(config), EWrongCap);
    assert!(config.version < rules::current_version(), EAlreadyCurrent);
    config.version = rules::current_version();
}

// === Getters ===

public fun fee_bps(config: &FeeConfig): u64 { config.fee_bps }

public fun treasury(config: &FeeConfig): address { config.treasury }

public fun max_fee_bps(): u64 { MAX_FEE_BPS }

public fun compute_fee(config: &FeeConfig, amount: u64): u64 {
    ((amount as u128) * (config.fee_bps as u128) / (BPS_DENOMINATOR as u128)) as u64
}

public fun version(config: &FeeConfig): u64 { config.version }

// === Internal ===

/// `collect` itself is not gated: it is only reachable through the
/// version-gated entry points of its callers.
fun assert_version(config: &FeeConfig) {
    assert!(config.version == rules::current_version(), EWrongVersion);
}

#[test_only]
public fun set_version_for_testing(config: &mut FeeConfig, version: u64) {
    config.version = version;
}

// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Platform fee configuration — the protocol's single fee lever.
///
/// Every monetization path in the package (payment rules,
/// subscriptions, post paywalls, tips) routes funds through `collect`,
/// which splits the platform's cut off the gross and forwards the
/// remainder to the creator. Design goals:
///
/// - **One canonical config.** `new` is package-internal and called
///   exactly once, from the package initializer, so a `&FeeConfig`
///   parameter can only ever be satisfied by that one object — a
///   creator cannot wire a zero-fee lookalike into a payment path.
/// - **A ceiling, not a promise.** `MAX_FEE_BPS` is a compile-time
///   constant: no cap holder — not the platform, not a future
///   governance — can push the fee above it. Creators price against a
///   bounded worst case instead of trusting an announcement.
/// - **A circuit breaker.** `collect` is the one gate all payments
///   pass through, so `paused` is a platform-wide payment stop: one
///   cap-gated flag halts subscriptions, paywalls, tips, and payment
///   rules at once. Non-payment interactions (posting, following,
///   username minting) are deliberately outside its reach — this is a
///   funds-protection lever, not a censorship lever. Being
///   non-custodial, a pause strands nothing: it only stops NEW
///   payments.
/// - **Governance-ready, fat-finger-proof.** The fee changes only
///   through `FeeConfigCap`. The cap is `key`-only, so generic
///   transfer tooling cannot move it; the only handoff path is the
///   explicit three-step flow below (propose → accept → execute),
///   in which the recipient must sign before the cap can move —
///   a mistyped address can never receive it.
module humming::platform;

use humming::rules;
use sui::coin::Coin;
use sui::event;

const EFeeTooHigh: u64 = 0;
const EWrongCap: u64 = 1;
const EInsufficientPayment: u64 = 2;
const EWrongVersion: u64 = 3;
const EAlreadyCurrent: u64 = 4;
const EPaused: u64 = 5;
const ENoPendingTransfer: u64 = 6;
const ENotProposedRecipient: u64 = 7;
const ETransferNotAccepted: u64 = 8;
const ECannotTransferToSelf: u64 = 9;

/// Hard ceiling on the platform fee: 5%. Creators are told the fee
/// starts at 0% and can never exceed this; the number is the promise.
const MAX_FEE_BPS: u64 = 500;
const BPS_DENOMINATOR: u64 = 10_000;

public struct FeeConfig has key {
    id: UID,
    version: u64,
    /// Platform cut in basis points (100 = 1%).
    fee_bps: u64,
    /// Where the platform's cut is sent.
    treasury: address,
    /// Circuit breaker: while true, `collect` aborts, halting every
    /// payment path in the package.
    paused: bool,
    /// Two-step cap handoff in flight, if any (see
    /// `propose_cap_transfer`).
    pending_cap_transfer: Option<PendingCapTransfer>,
}

/// Capability to change the fee (within `MAX_FEE_BPS`), the treasury
/// address, and the pause flag. `key`-only on purpose: it cannot be
/// wrapped, kiosked, or moved with `public_transfer` — the three-step
/// transfer flow in this module is its only way to change hands. The
/// intended endgame is handing it to a governance contract.
public struct FeeConfigCap has key {
    id: UID,
    config: ID,
}

public struct PendingCapTransfer has drop, store {
    to: address,
    accepted: bool,
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

public struct PauseChanged has copy, drop {
    config: ID,
    paused: bool,
}

public struct CapTransferProposed has copy, drop {
    config: ID,
    to: address,
}

public struct CapTransferAccepted has copy, drop {
    config: ID,
    to: address,
}

public struct CapTransferExecuted has copy, drop {
    config: ID,
    to: address,
}

public struct CapTransferCanceled has copy, drop {
    config: ID,
}

/// Create and share the canonical fee config; the cap goes to the
/// sender. Package-internal: only the package initializer calls this,
/// exactly once.
public(package) fun new(fee_bps: u64, treasury: address, ctx: &mut TxContext) {
    assert!(fee_bps <= MAX_FEE_BPS, EFeeTooHigh);
    let config = FeeConfig {
        id: object::new(ctx),
        version: rules::current_version(),
        fee_bps,
        treasury,
        paused: false,
        pending_cap_transfer: option::none(),
    };
    let cap = FeeConfigCap { id: object::new(ctx), config: object::id(&config) };
    event::emit(FeeConfigCreated { config: object::id(&config), fee_bps, treasury });
    transfer::share_object(config);
    // `FeeConfigCap` has no `store`, so the initializer cannot move it
    // itself; it is delivered here.
    transfer::transfer(cap, ctx.sender());
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
    assert!(!config.paused, EPaused);
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
    assert_cap(config, cap);
    assert!(fee_bps <= MAX_FEE_BPS, EFeeTooHigh);
    config.fee_bps = fee_bps;
    event::emit(FeeChanged { config: object::id(config), fee_bps });
}

public fun set_treasury(config: &mut FeeConfig, cap: &FeeConfigCap, treasury: address) {
    assert_version(config);
    assert_cap(config, cap);
    config.treasury = treasury;
    event::emit(TreasuryChanged { config: object::id(config), treasury });
}

/// Flip the payment circuit breaker. Deliberately NOT version-gated:
/// the emergency stop must work even on a config stranded on an old
/// version mid-upgrade — a safety lever must never be hostage to
/// `migrate`.
public fun set_paused(config: &mut FeeConfig, cap: &FeeConfigCap, paused: bool) {
    assert_cap(config, cap);
    config.paused = paused;
    event::emit(PauseChanged { config: object::id(config), paused });
}

/// Bring a fee config created under an older package version up to
/// the current one.
public fun migrate(config: &mut FeeConfig, cap: &FeeConfigCap) {
    assert_cap(config, cap);
    assert!(config.version < rules::current_version(), EAlreadyCurrent);
    config.version = rules::current_version();
}

// === Cap handoff (three-step: propose → accept → execute) ===
//
// The cap is the platform's one irreplaceable object: send it to a
// dead address and the fee, treasury, and pause levers are lost
// forever. So its transfer requires the recipient to prove liveness
// by signing an acceptance before the current holder can release it.
// None of these steps are version-gated, for the same reason as
// `set_paused`: recovering control must not depend on `migrate`.

/// Step 1 — the current holder proposes a handoff. Re-proposing
/// overwrites any pending proposal.
public fun propose_cap_transfer(
    config: &mut FeeConfig,
    cap: &FeeConfigCap,
    to: address,
    ctx: &TxContext,
) {
    assert_cap(config, cap);
    assert!(to != ctx.sender(), ECannotTransferToSelf);
    config.pending_cap_transfer = option::some(PendingCapTransfer { to, accepted: false });
    event::emit(CapTransferProposed { config: object::id(config), to });
}

/// Step 2 — the proposed recipient signs to prove the address is live
/// and willing.
public fun accept_cap_transfer(config: &mut FeeConfig, ctx: &TxContext) {
    accept_internal(config, ctx.sender());
}

/// Step 2, object variant — a governance contract accepts via its
/// privileged `&mut UID` (only the object's owning module can produce
/// one), for the roadmap where the cap's destination is a shared
/// governance object rather than an account.
public fun accept_cap_transfer_as_object(config: &mut FeeConfig, from: &mut UID) {
    accept_internal(config, from.to_address());
}

/// Step 3 — the current holder releases the cap. Impossible until the
/// recipient has accepted.
public fun execute_cap_transfer(config: &mut FeeConfig, cap: FeeConfigCap, _ctx: &TxContext) {
    assert!(cap.config == object::id(config), EWrongCap);
    assert!(config.pending_cap_transfer.is_some(), ENoPendingTransfer);
    let PendingCapTransfer { to, accepted } = config.pending_cap_transfer.extract();
    assert!(accepted, ETransferNotAccepted);
    transfer::transfer(cap, to);
    event::emit(CapTransferExecuted { config: object::id(config), to });
}

/// Withdraw a pending proposal (accepted or not).
public fun cancel_cap_transfer(config: &mut FeeConfig, cap: &FeeConfigCap) {
    assert_cap(config, cap);
    assert!(config.pending_cap_transfer.is_some(), ENoPendingTransfer);
    config.pending_cap_transfer = option::none();
    event::emit(CapTransferCanceled { config: object::id(config) });
}

// === Getters ===

public fun fee_bps(config: &FeeConfig): u64 { config.fee_bps }

public fun treasury(config: &FeeConfig): address { config.treasury }

public fun is_paused(config: &FeeConfig): bool { config.paused }

public fun max_fee_bps(): u64 { MAX_FEE_BPS }

public fun compute_fee(config: &FeeConfig, amount: u64): u64 {
    ((amount as u128) * (config.fee_bps as u128) / (BPS_DENOMINATOR as u128)) as u64
}

public fun version(config: &FeeConfig): u64 { config.version }

public fun pending_cap_transfer_to(config: &FeeConfig): Option<address> {
    config.pending_cap_transfer.map_ref!(|p| p.to)
}

public fun pending_cap_transfer_accepted(config: &FeeConfig): Option<bool> {
    config.pending_cap_transfer.map_ref!(|p| p.accepted)
}

// === Internal ===

fun accept_internal(config: &mut FeeConfig, caller: address) {
    assert!(config.pending_cap_transfer.is_some(), ENoPendingTransfer);
    let pending = config.pending_cap_transfer.borrow_mut();
    assert!(caller == pending.to, ENotProposedRecipient);
    pending.accepted = true;
    event::emit(CapTransferAccepted { config: object::id(config), to: caller });
}

fun assert_cap(config: &FeeConfig, cap: &FeeConfigCap) {
    assert!(cap.config == object::id(config), EWrongCap);
}

/// `collect` itself is not version-gated: it is only reachable through
/// the version-gated entry points of its callers (its own gate is the
/// pause flag).
fun assert_version(config: &FeeConfig) {
    assert!(config.version == rules::current_version(), EWrongVersion);
}

#[test_only]
public fun set_version_for_testing(config: &mut FeeConfig, version: u64) {
    config.version = version;
}

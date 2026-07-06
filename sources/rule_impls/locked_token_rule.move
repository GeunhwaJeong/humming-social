// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Locked-token rule: a flash-proof variant of `token_gated_rule`.
///
/// `token_gated_rule` proves possession at a point in time — the same
/// guarantee as an EVM `balanceOf` check — so a coin can be borrowed,
/// shown, and returned inside one transaction. This rule closes that
/// hole: the proof requires coins to be **deposited in a `Lock`**, and
/// every successful proof extends the lock's release time to at least
/// `now + min_lock_ms`. Borrowed funds cannot satisfy it, because they
/// could not be returned within the lending transaction.
///
/// One `Lock<T>` per account serves any number of rule sets over the
/// same coin type (proofs only extend the release time), so capital is
/// reused across gates rather than locked per gate.
///
/// The lock is bound to its owner by the object system itself: `Lock`
/// is `key`-only (no `store`), so it cannot be wrapped into a shared
/// "lock pool" or moved with `public_transfer`. Passing `&mut Lock` to
/// `prove` therefore requires owning it, and a request's account is
/// always the transaction sender — the proving account and the capital
/// owner are the same party by construction, with no owner field to
/// manage (and no rebind function to become a loophole).
module humming::locked_token_rule;

use humming::rules::{Self, Request, RuleSet, RuleSetCap};
use haneul::balance::{Self, Balance};
use haneul::clock::Clock;
use haneul::coin::{Self, Coin};
use haneul::event;

const EInsufficientLockedBalance: u64 = 0;
const EStillLocked: u64 = 1;

public struct LockedTokenRule has drop {}

public struct Config<phantom T> has store {
    /// Minimum locked balance required by the proof.
    min_balance: u64,
    /// How long the lock must remain in force after each proof.
    min_lock_ms: u64,
}

/// Coins committed by an account. Deliberately `key`-only: ownership
/// of this object is the proof authorization (see module doc), and
/// funds leave it only through `withdraw` after `unlock_ms`.
public struct Lock<phantom T> has key {
    id: UID,
    balance: Balance<T>,
    unlock_ms: u64,
}

// === Events ===
//
// A `Lock` is module-owned persistent state: unlike a coin transfer,
// nothing else on chain records its lifecycle, so without events a
// wallet cannot answer "when do my funds unlock?" short of polling the
// object. Because a lock is soulbound, the `owner` in `LockCreated` is
// permanent — one event determines ownership for the lock's lifetime.
// `Deposited`/`Withdrawn` carry the post-change balance so indexers
// never need a state read to track it.

public struct LockCreated has copy, drop {
    lock: ID,
    owner: address,
}

public struct Deposited has copy, drop {
    lock: ID,
    amount: u64,
    /// Locked balance after the deposit.
    balance: u64,
}

public struct Withdrawn has copy, drop {
    lock: ID,
    amount: u64,
    /// Locked balance after the withdrawal.
    balance: u64,
}

/// Emitted by `prove` only when the release time actually moves — the
/// event stream mirrors state changes, not proof attempts.
public struct LockExtended has copy, drop {
    lock: ID,
    /// The rule set whose proof extended the lock.
    set: ID,
    /// The new release time.
    unlock_ms: u64,
}

public struct LockDestroyed has copy, drop {
    lock: ID,
}

public fun add<OP, T>(
    set: &mut RuleSet<OP>,
    cap: &RuleSetCap,
    min_balance: u64,
    min_lock_ms: u64,
    required: bool,
) {
    rules::add(LockedTokenRule {}, set, cap, Config<T> { min_balance, min_lock_ms }, required)
}

public fun remove<OP, T>(set: &mut RuleSet<OP>, cap: &RuleSetCap) {
    let Config<T> {
        min_balance: _,
        min_lock_ms: _,
    } = rules::remove<OP, LockedTokenRule, Config<T>>(set, cap);
}

// === Lock management ===

public fun new_lock<T>(ctx: &mut TxContext): Lock<T> {
    let lock = Lock { id: object::new(ctx), balance: balance::zero(), unlock_ms: 0 };
    // The sender is the permanent owner: `Lock` has no `store`, and the
    // module's only transfer path (`keep`) sends to the sender.
    event::emit(LockCreated { lock: object::id(&lock), owner: ctx.sender() });
    lock
}

/// Send a lock to the sender. Since `Lock` has no `store`, a PTB's
/// `TransferObjects` cannot move it — this is the module-mediated way
/// to finish a create → deposit → prove → keep transaction.
public fun keep<T>(lock: Lock<T>, ctx: &TxContext) {
    transfer::transfer(lock, ctx.sender())
}

public fun deposit<T>(lock: &mut Lock<T>, payment: Coin<T>) {
    let amount = payment.value();
    let balance = lock.balance.join(payment.into_balance());
    event::emit(Deposited { lock: object::id(lock), amount, balance });
}

/// Withdraw from the lock. Only possible once every proof's lock
/// period has elapsed.
public fun withdraw<T>(
    lock: &mut Lock<T>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T> {
    assert!(clock.timestamp_ms() >= lock.unlock_ms, EStillLocked);
    let funds = coin::take(&mut lock.balance, amount, ctx);
    event::emit(Withdrawn { lock: object::id(lock), amount, balance: lock.balance.value() });
    funds
}

/// Destroy an emptied lock.
public fun destroy_empty<T>(lock: Lock<T>) {
    let Lock { id, balance, unlock_ms: _ } = lock;
    balance.destroy_zero();
    event::emit(LockDestroyed { lock: id.to_inner() });
    id.delete();
}

// === Proof ===

/// Prove a locked holding of at least the configured balance and stamp
/// the request. Extends the lock so the funds stay committed for at
/// least `min_lock_ms` from now.
public fun prove<OP, T>(
    set: &RuleSet<OP>,
    req: &mut Request<OP>,
    lock: &mut Lock<T>,
    clock: &Clock,
) {
    let config = rules::config<OP, LockedTokenRule, Config<T>>(set);
    assert!(lock.balance.value() >= config.min_balance, EInsufficientLockedBalance);
    let until = clock.timestamp_ms() + config.min_lock_ms;
    if (until > lock.unlock_ms) {
        lock.unlock_ms = until;
        event::emit(LockExtended {
            lock: object::id(lock),
            set: object::id(set),
            unlock_ms: until,
        });
    };
    rules::add_approval(LockedTokenRule {}, set, req);
}

// === Getters ===

public fun locked_balance<T>(lock: &Lock<T>): u64 { lock.balance.value() }

public fun unlock_ms<T>(lock: &Lock<T>): u64 { lock.unlock_ms }

public fun min_balance<OP, T>(set: &RuleSet<OP>): u64 {
    rules::config<OP, LockedTokenRule, Config<T>>(set).min_balance
}

public fun min_lock_ms<OP, T>(set: &RuleSet<OP>): u64 {
    rules::config<OP, LockedTokenRule, Config<T>>(set).min_lock_ms
}

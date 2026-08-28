// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Pay-to-interact rule (Lens V3 `SimplePaymentRule` family: paid
/// follows, paid group joins, paid posting).
///
/// Generic over the operation `OP` and the payment coin type `T`, so
/// the same module gates follows, joins, or posts in any currency.
/// Payments run through `humming::platform`, which splits the
/// platform's cut off before the remainder reaches the recipient
/// (the same shape as Lens V3's treasury fee inside payment rules).
module humming::simple_payment_rule;

use humming::platform::{Self, FeeConfig};
use humming::rules::{Self, Request, RuleSet, RuleSetCap};
use sui::coin::Coin;

const EAlreadyPaid: u64 = 1;
const EPriceMismatch: u64 = 2;

public struct SimplePaymentRule has drop {}

public struct Config<phantom T> has store {
    amount: u64,
    recipient: address,
}

public fun add<OP, T>(
    set: &mut RuleSet<OP>,
    cap: &RuleSetCap,
    amount: u64,
    recipient: address,
    required: bool,
) {
    rules::add(SimplePaymentRule {}, set, cap, Config<T> { amount, recipient }, required)
}

public fun remove<OP, T>(set: &mut RuleSet<OP>, cap: &RuleSetCap) {
    let Config<T> { amount: _, recipient: _ } = rules::remove<OP, SimplePaymentRule, Config<T>>(
        set,
        cap,
    );
}

/// Pay the configured amount and stamp the request. The exact amount
/// is split off `payment`, so callers can pass any coin holding at
/// least that much and keep the change. Paying the same rule set twice
/// for one request aborts rather than taking a second payment.
///
/// `expected_amount` is the amount the payer saw when signing: if the
/// rule was re-configured with a higher amount in the meantime, the
/// payment aborts instead of silently charging more.
public fun pay<OP, T>(
    set: &RuleSet<OP>,
    fee_config: &FeeConfig,
    expected_amount: u64,
    req: &mut Request<OP>,
    payment: &mut Coin<T>,
    ctx: &mut TxContext,
) {
    assert!(!rules::has_approval<OP, SimplePaymentRule>(set, req), EAlreadyPaid);
    let config = rules::config<OP, SimplePaymentRule, Config<T>>(set);
    assert!(config.amount == expected_amount, EPriceMismatch);
    platform::collect(fee_config, payment, config.amount, config.recipient, ctx);
    rules::add_approval(SimplePaymentRule {}, set, req);
}

public fun amount<OP, T>(set: &RuleSet<OP>): u64 {
    rules::config<OP, SimplePaymentRule, Config<T>>(set).amount
}

public fun recipient<OP, T>(set: &RuleSet<OP>): address {
    rules::config<OP, SimplePaymentRule, Config<T>>(set).recipient
}

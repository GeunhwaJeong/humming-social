// Copyright (c) 2026 Geunhwa Jeong
// SPDX-License-Identifier: Apache-2.0

/// Token-gated rule (Lens V3 `TokenGatedRule` family: token-gated
/// follows, joins, replies).
///
/// The caller proves possession by showing a coin at interaction time.
/// Like the EVM original's `balanceOf` check, this is a point-in-time
/// proof — the coin is not locked and can be moved afterwards, so it
/// can be satisfied with borrowed funds inside one transaction. When
/// that matters (high-value gates), use `locked_token_rule`, which
/// requires the coins to stay locked after the proof.
module humming::token_gated_rule;

use humming::rules::{Self, Request, RuleSet, RuleSetCap};
use sui::coin::Coin;

const EInsufficientBalance: u64 = 0;

/// Generic over the coin type so each coin gate is its own rule
/// identity: "hold coin X OR hold coin Y" is two any-of entries in one
/// rule set, which a non-generic witness could not express (rule
/// identity is the witness type name, and a rule cannot be attached
/// twice).
public struct TokenGatedRule<phantom T> has drop {}

public struct Config<phantom T> has store {
    min_balance: u64,
}

public fun add<OP, T>(set: &mut RuleSet<OP>, cap: &RuleSetCap, min_balance: u64, required: bool) {
    rules::add(TokenGatedRule<T> {}, set, cap, Config<T> { min_balance }, required)
}

public fun remove<OP, T>(set: &mut RuleSet<OP>, cap: &RuleSetCap) {
    let Config<T> { min_balance: _ } = rules::remove<OP, TokenGatedRule<T>, Config<T>>(set, cap);
}

/// Show a coin holding at least the configured balance and stamp the
/// request. The coin is only read, never taken.
public fun prove<OP, T>(set: &RuleSet<OP>, req: &mut Request<OP>, proof: &Coin<T>) {
    let config = rules::config<OP, TokenGatedRule<T>, Config<T>>(set);
    assert!(proof.value() >= config.min_balance, EInsufficientBalance);
    rules::add_approval(TokenGatedRule<T> {}, set, req);
}

public fun min_balance<OP, T>(set: &RuleSet<OP>): u64 {
    rules::config<OP, TokenGatedRule<T>, Config<T>>(set).min_balance
}

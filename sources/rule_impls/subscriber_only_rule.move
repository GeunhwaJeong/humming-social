// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Subscriber-only rule: gate any operation on holding an *active*
/// subscription to a configured tier.
///
/// This is the bridge between `subscriptions` and the rule framework:
/// attach it to a post's reply rules for subscriber-only comment
/// sections, to follow rules, to group join rules, and so on. The
/// check is against the subscription's expiry at proof time, so a
/// lapsed subscriber is rejected without any cleanup transaction.
module humming::subscriber_only_rule;

use humming::rules::{Self, Request, RuleSet, RuleSetCap};
use humming::subscriptions::{Self, Tier};
use haneul::clock::Clock;

const EWrongTier: u64 = 0;
const ENotSubscribed: u64 = 1;

public struct SubscriberOnlyRule has drop {}

public struct Config has store {
    tier: ID,
}

public fun add<OP>(set: &mut RuleSet<OP>, cap: &RuleSetCap, tier: ID, required: bool) {
    rules::add(SubscriberOnlyRule {}, set, cap, Config { tier }, required)
}

public fun remove<OP>(set: &mut RuleSet<OP>, cap: &RuleSetCap) {
    let Config { tier: _ } = rules::remove<OP, SubscriberOnlyRule, Config>(set, cap);
}

/// Prove the requesting account holds an active subscription to the
/// configured tier, and stamp the request.
public fun prove<OP, T>(
    set: &RuleSet<OP>,
    req: &mut Request<OP>,
    tier: &Tier<T>,
    clock: &Clock,
) {
    let config = rules::config<OP, SubscriberOnlyRule, Config>(set);
    assert!(object::id(tier) == config.tier, EWrongTier);
    assert!(
        subscriptions::is_active_subscriber(tier, rules::request_account(req), clock),
        ENotSubscribed,
    );
    rules::add_approval(SubscriberOnlyRule {}, set, req);
}

public fun tier<OP>(set: &RuleSet<OP>): ID {
    rules::config<OP, SubscriberOnlyRule, Config>(set).tier
}

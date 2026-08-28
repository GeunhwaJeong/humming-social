// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Subscriber-only rule: gate any operation on holding an *active*
/// subscription to **any of the configured tiers**.
///
/// This is the bridge between `subscriptions` and the rule framework:
/// attach it to a post's reply rules for subscriber-only comment
/// sections, to follow rules, to group join rules, and so on.
///
/// The allowed-tier list is a vector so one rule instance expresses
/// multi-tier access ("silver OR gold subscribers"). This matters
/// because rule identity is the witness type name: the same rule
/// cannot be attached to a rule set twice, so tiered access must live
/// inside one config (the role Lens V3's configSalt plays for its
/// multi-instance rules).
///
/// The check is against the subscription's expiry at proof time, so a
/// lapsed subscriber is rejected without any cleanup transaction.
module humming::subscriber_only_rule;

use humming::rules::{Self, Request, RuleSet, RuleSetCap};
use humming::subscriptions::{Self, Tier};
use sui::clock::Clock;

const EWrongTier: u64 = 0;
const ENotSubscribed: u64 = 1;
const ENoTiers: u64 = 2;

public struct SubscriberOnlyRule has drop {}

public struct Config has store {
    /// Tiers whose active subscribers pass the gate (any one suffices).
    tiers: vector<ID>,
}

public fun add<OP>(set: &mut RuleSet<OP>, cap: &RuleSetCap, tiers: vector<ID>, required: bool) {
    assert!(!tiers.is_empty(), ENoTiers);
    rules::add(SubscriberOnlyRule {}, set, cap, Config { tiers }, required)
}

public fun remove<OP>(set: &mut RuleSet<OP>, cap: &RuleSetCap) {
    let Config { tiers: _ } = rules::remove<OP, SubscriberOnlyRule, Config>(set, cap);
}

/// Prove the requesting account holds an active subscription to one of
/// the configured tiers, and stamp the request.
public fun prove<OP, T>(
    set: &RuleSet<OP>,
    req: &mut Request<OP>,
    tier: &Tier<T>,
    clock: &Clock,
) {
    let config = rules::config<OP, SubscriberOnlyRule, Config>(set);
    assert!(config.tiers.contains(&object::id(tier)), EWrongTier);
    assert!(
        subscriptions::is_active_subscriber(tier, rules::request_account(req), clock),
        ENotSubscribed,
    );
    rules::add_approval(SubscriberOnlyRule {}, set, req);
}

public fun tiers<OP>(set: &RuleSet<OP>): vector<ID> {
    rules::config<OP, SubscriberOnlyRule, Config>(set).tiers
}

// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Rule framework for the social primitives.
///
/// Lens V3 (Solidity) attaches rules to primitives via dynamic dispatch:
/// a stored contract address + function selector called at interaction
/// time. Move has no dynamic dispatch, so this module uses the
/// hot-potato receipt pattern instead (the same family as
/// `sui::transfer_policy`):
///
/// 1. A primitive issues a `Request<OP>` hot potato when an interaction
///    starts (`request_*` functions).
/// 2. Rule modules validate the interaction and stamp the request via
///    `add_approval`. The stamp records both the rule witness type AND
///    the exact `RuleSet` object the proof ran against, so a stamp
///    obtained against one rule set can never satisfy another (e.g.
///    paying account A's cheap follow fee cannot unlock account B's
///    expensive one).
/// 3. The primitive confirms the request against its rule set(s) before
///    committing state. Required rules must all be stamped; if any
///    "any-of" rules are configured, at least one must be stamped.
///
/// `RuleSet` is a standalone shared object (like `TransferPolicy`)
/// rather than a field embedded in the primitive, because programmable
/// transaction blocks cannot pass references returned from function
/// calls — but they can pass shared objects directly into rule modules.
module humming::rules;

use std::string::String;
use std::type_name::{Self, TypeName};
use sui::bag::{Self, Bag};
use sui::vec_set::{Self, VecSet};

const ERuleAlreadyAdded: u64 = 0;
const ERuleNotFound: u64 = 1;
const ERequiredRuleNotSatisfied: u64 = 2;
const EAnyOfRuleNotSatisfied: u64 = 3;
const ETooManyRules: u64 = 4;
const EWrongCap: u64 = 5;
const EWrongVersion: u64 = 6;
const EAlreadyCurrent: u64 = 7;

/// Mirrors MAX_AMOUNT_OF_RULES in Lens V3.
const MAX_RULES: u64 = 20;

/// Version stamped on every shared object of the package (primitives
/// read it via `current_version`, so one bump moves the whole package
/// in lockstep). Mutating entry points reject objects stamped with a
/// different version; after an upgrade bumps this constant, admins run
/// their object's `migrate` to re-enable it. This is what makes
/// retiring an old package version *enforceable* — published versions
/// stay callable forever, but their writes abort here.
const VERSION: u64 = 1;

/// A set of rules gating one operation `OP` of one primitive instance.
/// Shared object; mutation is gated by the matching `RuleSetCap`.
public struct RuleSet<phantom OP> has key, store {
    id: UID,
    version: u64,
    required: VecSet<TypeName>,
    any_of: VecSet<TypeName>,
    /// Per-rule configuration, keyed by the rule witness type name.
    configs: Bag,
}

/// Capability to add/remove rules on one specific `RuleSet`.
public struct RuleSetCap has key, store {
    id: UID,
    set: ID,
}

/// A stamp left by a rule module on a `Request`. Binds the rule witness
/// to the exact rule set instance the proof was validated against.
public struct Approval has copy, drop, store {
    rule: TypeName,
    set: ID,
}

/// Hot potato issued by a primitive at the start of an interaction.
/// Must be confirmed (or destroyed by the primitive) within the same
/// transaction.
public struct Request<phantom OP> {
    /// Pairing key binding this request to the primitive-specific
    /// ticket it was issued together with.
    key: address,
    /// The account performing the interaction.
    account: address,
    approvals: VecSet<Approval>,
}

// === Package-internal API (called by the primitive modules) ===

public(package) fun new<OP>(ctx: &mut TxContext): (RuleSet<OP>, RuleSetCap) {
    let set = RuleSet<OP> {
        id: object::new(ctx),
        version: VERSION,
        required: vec_set::empty(),
        any_of: vec_set::empty(),
        configs: bag::new(ctx),
    };
    let cap = RuleSetCap { id: object::new(ctx), set: object::id(&set) };
    (set, cap)
}

public(package) fun new_request<OP>(key: address, account: address): Request<OP> {
    Request { key, account, approvals: vec_set::empty() }
}

/// Check a request against a rule set without consuming it, so a single
/// request can be validated against multiple sets (e.g. graph-level
/// rules AND the target account's follow rules).
public(package) fun check<OP>(set: &RuleSet<OP>, req: &Request<OP>) {
    let set_id = object::id(set);
    let required = set.required.keys();
    let mut i = 0;
    while (i < required.length()) {
        assert!(
            req.approvals.contains(&Approval { rule: required[i], set: set_id }),
            ERequiredRuleNotSatisfied,
        );
        i = i + 1;
    };
    if (!set.any_of.is_empty()) {
        let any_of = set.any_of.keys();
        let mut satisfied = false;
        let mut j = 0;
        while (j < any_of.length()) {
            if (req.approvals.contains(&Approval { rule: any_of[j], set: set_id })) {
                satisfied = true;
                break
            };
            j = j + 1;
        };
        assert!(satisfied, EAnyOfRuleNotSatisfied);
    };
}

public(package) fun confirm<OP>(set: &RuleSet<OP>, req: Request<OP>) {
    check(set, &req);
    destroy(req);
}

public(package) fun destroy<OP>(req: Request<OP>) {
    let Request { key: _, account: _, approvals: _ } = req;
}

// === Rule management (called by rule modules; gated by witness + cap) ===

/// Add a rule to the set. The witness ensures only the rule module can
/// wire itself in (with a well-formed config); the cap ensures only the
/// rule set's admin can decide WHICH rules apply.
public fun add<OP, R: drop, C: store>(
    _: R,
    set: &mut RuleSet<OP>,
    cap: &RuleSetCap,
    config: C,
    required: bool,
) {
    assert_version(set);
    assert!(cap.set == object::id(set), EWrongCap);
    let rule = type_name::with_defining_ids<R>();
    assert!(!set.required.contains(&rule) && !set.any_of.contains(&rule), ERuleAlreadyAdded);
    assert!(set.required.length() + set.any_of.length() < MAX_RULES, ETooManyRules);
    if (required) {
        set.required.insert(rule);
    } else {
        set.any_of.insert(rule);
    };
    set.configs.add(rule, config);
}

/// Remove a rule and return its config for the rule module to unpack.
public fun remove<OP, R: drop, C: store>(set: &mut RuleSet<OP>, cap: &RuleSetCap): C {
    assert_version(set);
    assert!(cap.set == object::id(set), EWrongCap);
    let rule = type_name::with_defining_ids<R>();
    if (set.required.contains(&rule)) {
        set.required.remove(&rule);
    } else {
        assert!(set.any_of.contains(&rule), ERuleNotFound);
        set.any_of.remove(&rule);
    };
    set.configs.remove(rule)
}

public fun config<OP, R: drop, C: store>(set: &RuleSet<OP>): &C {
    bag::borrow(&set.configs, type_name::with_defining_ids<R>())
}

public fun has_rule<OP, R: drop>(set: &RuleSet<OP>): bool {
    let rule = type_name::with_defining_ids<R>();
    set.required.contains(&rule) || set.any_of.contains(&rule)
}

public fun is_empty<OP>(set: &RuleSet<OP>): bool {
    set.required.is_empty() && set.any_of.is_empty()
}

/// Stamp an approval on the request, recording the exact rule set the
/// proof was validated against.
public fun add_approval<OP, R: drop>(_: R, set: &RuleSet<OP>, req: &mut Request<OP>) {
    let approval = Approval { rule: type_name::with_defining_ids<R>(), set: object::id(set) };
    if (!req.approvals.contains(&approval)) {
        req.approvals.insert(approval);
    };
}

/// Whether `req` already carries the stamp of rule `R` for this exact
/// rule set. Lets rule modules abort instead of silently no-oping when
/// a proof (e.g. a payment) is submitted twice.
public fun has_approval<OP, R: drop>(set: &RuleSet<OP>, req: &Request<OP>): bool {
    req.approvals.contains(&Approval {
        rule: type_name::with_defining_ids<R>(),
        set: object::id(set),
    })
}

public fun request_key<OP>(req: &Request<OP>): address { req.key }

public fun request_account<OP>(req: &Request<OP>): address { req.account }

// === Versioning ===

/// Bring a rule set created under an older package version up to the
/// current one, re-enabling its administration after an upgrade.
public fun migrate<OP>(set: &mut RuleSet<OP>, cap: &RuleSetCap) {
    assert!(cap.set == object::id(set), EWrongCap);
    assert!(set.version < VERSION, EAlreadyCurrent);
    set.version = VERSION;
}

public fun current_version(): u64 { VERSION }

/// Human-readable package identity, answering "what is live on-chain?"
/// with one RPC call. Bump alongside `VERSION`.
public fun type_and_version(): String { b"Humming 1.0.0".to_string() }

public fun version<OP>(set: &RuleSet<OP>): u64 { set.version }

/// Only the mutating entry points are gated. Read/stamp paths stay
/// open on purpose: stamps only matter to `confirm`, which primitives
/// reach behind their own version gates.
fun assert_version<OP>(set: &RuleSet<OP>) {
    assert!(set.version == VERSION, EWrongVersion);
}

#[test_only]
public fun set_version_for_testing<OP>(set: &mut RuleSet<OP>, version: u64) {
    set.version = version;
}

// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Username namespace primitive (Lens V3 `Namespace`).
///
/// A `Namespace` is a shared registry mapping usernames to accounts.
/// Minting a username produces a transferable `Username` object — the
/// Move counterpart of Lens V3's username ERC-721 — while assignment
/// (which account the name currently points at) lives in the registry
/// tables so reverse lookup stays on-chain.
module humming::namespace;

use humming::rules::{Self, Request, RuleSet, RuleSetCap};
use std::string::String;
use haneul::event;
use haneul::table::{Self, Table};

const ENameTaken: u64 = 0;
const EInvalidName: u64 = 1;
const EWrongNamespace: u64 = 2;
const EAlreadyAssigned: u64 = 3;
const ENotAssigned: u64 = 4;
const EWrongCap: u64 = 5;
const EWrongRuleSet: u64 = 6;
const EKeyMismatch: u64 = 7;
const EUsernameStillAssigned: u64 = 8;

/// Operation marker: minting a new username.
public struct CreateUsernameOp {}

public struct Namespace has key {
    id: UID,
    name: String,
    metadata_uri: String,
    /// ID of the shared `RuleSet<CreateUsernameOp>` gating minting.
    create_rules: ID,
    /// Every minted (and not burned) username.
    taken: Table<String, bool>,
    username_to_account: Table<String, address>,
    account_to_username: Table<address, String>,
}

public struct NamespaceAdminCap has key, store {
    id: UID,
    namespace: ID,
}

/// Ownership token for a username. Freely transferable/tradeable;
/// holding it is what authorizes assignment.
public struct Username has key, store {
    id: UID,
    namespace: ID,
    name: String,
}

/// Hot potato paired with a `Request<CreateUsernameOp>`.
public struct CreateUsernameTicket {
    namespace: ID,
    key: address,
    account: address,
    name: String,
}

public struct NamespaceCreated has copy, drop {
    namespace: ID,
    name: String,
}

public struct UsernameCreated has copy, drop {
    namespace: ID,
    name: String,
    by: address,
}

public struct UsernameAssigned has copy, drop {
    namespace: ID,
    name: String,
    account: address,
}

public struct UsernameUnassigned has copy, drop {
    namespace: ID,
    name: String,
    account: address,
}

public struct UsernameBurned has copy, drop {
    namespace: ID,
    name: String,
}

/// Create a namespace. Shares the `Namespace` and its creation rule
/// set; returns the admin cap and the rule set cap to the caller.
public fun create(
    name: String,
    metadata_uri: String,
    ctx: &mut TxContext,
): (NamespaceAdminCap, RuleSetCap) {
    let (set, set_cap) = rules::new<CreateUsernameOp>(ctx);
    let ns = Namespace {
        id: object::new(ctx),
        name,
        metadata_uri,
        create_rules: object::id(&set),
        taken: table::new(ctx),
        username_to_account: table::new(ctx),
        account_to_username: table::new(ctx),
    };
    let admin_cap = NamespaceAdminCap { id: object::new(ctx), namespace: object::id(&ns) };
    event::emit(NamespaceCreated { namespace: object::id(&ns), name: ns.name });
    transfer::public_share_object(set);
    transfer::share_object(ns);
    (admin_cap, set_cap)
}

// === Username minting (rule-gated) ===

public fun request_create_username(
    ns: &Namespace,
    name: String,
    ctx: &mut TxContext,
): (CreateUsernameTicket, Request<CreateUsernameOp>) {
    assert_valid_name(&name);
    assert!(!ns.taken.contains(name), ENameTaken);
    let key = ctx.fresh_object_address();
    let account = ctx.sender();
    let ticket = CreateUsernameTicket { namespace: object::id(ns), key, account, name };
    (ticket, rules::new_request(key, account))
}

public fun execute_create_username(
    ns: &mut Namespace,
    set: &RuleSet<CreateUsernameOp>,
    ticket: CreateUsernameTicket,
    req: Request<CreateUsernameOp>,
    ctx: &mut TxContext,
): Username {
    let CreateUsernameTicket { namespace, key, account: _, name } = ticket;
    assert!(namespace == object::id(ns), EWrongNamespace);
    assert!(object::id(set) == ns.create_rules, EWrongRuleSet);
    assert!(key == rules::request_key(&req), EKeyMismatch);
    rules::confirm(set, req);
    mint(ns, name, ctx)
}

/// Admin mint that bypasses creation rules (reserved handles etc. —
/// covers Lens V3's `UsernameReservedNamespaceRule` use case).
public fun admin_create_username(
    ns: &mut Namespace,
    cap: &NamespaceAdminCap,
    name: String,
    ctx: &mut TxContext,
): Username {
    assert!(cap.namespace == object::id(ns), EWrongCap);
    assert_valid_name(&name);
    mint(ns, name, ctx)
}

// === Assignment ===

/// Assign the username to the sender. Requires holding the `Username`
/// object.
public fun assign(ns: &mut Namespace, username: &Username, ctx: &TxContext) {
    assert!(username.namespace == object::id(ns), EWrongNamespace);
    let account = ctx.sender();
    assert!(!ns.username_to_account.contains(username.name), EAlreadyAssigned);
    assert!(!ns.account_to_username.contains(account), EAlreadyAssigned);
    ns.username_to_account.add(username.name, account);
    ns.account_to_username.add(account, username.name);
    event::emit(UsernameAssigned { namespace: object::id(ns), name: username.name, account });
}

/// Unassign by the account the username is currently assigned to.
public fun unassign_self(ns: &mut Namespace, ctx: &TxContext) {
    let account = ctx.sender();
    assert!(ns.account_to_username.contains(account), ENotAssigned);
    let name = ns.account_to_username.remove(account);
    ns.username_to_account.remove(name);
    event::emit(UsernameUnassigned { namespace: object::id(ns), name, account });
}

/// Unassign by whoever holds the `Username` object (e.g. after buying
/// an assigned username on a marketplace).
public fun unassign(ns: &mut Namespace, username: &Username) {
    assert!(username.namespace == object::id(ns), EWrongNamespace);
    assert!(ns.username_to_account.contains(username.name), ENotAssigned);
    let account = ns.username_to_account.remove(username.name);
    ns.account_to_username.remove(account);
    event::emit(UsernameUnassigned { namespace: object::id(ns), name: username.name, account });
}

/// Burn an unassigned username, freeing the name for re-minting.
public fun burn(ns: &mut Namespace, username: Username) {
    let Username { id, namespace, name } = username;
    assert!(namespace == object::id(ns), EWrongNamespace);
    assert!(!ns.username_to_account.contains(name), EUsernameStillAssigned);
    ns.taken.remove(name);
    id.delete();
    event::emit(UsernameBurned { namespace, name });
}

// === Admin ===

public fun set_metadata_uri(ns: &mut Namespace, cap: &NamespaceAdminCap, metadata_uri: String) {
    assert!(cap.namespace == object::id(ns), EWrongCap);
    ns.metadata_uri = metadata_uri;
}

// === Getters ===

public fun is_taken(ns: &Namespace, name: String): bool {
    ns.taken.contains(name)
}

public fun account_of(ns: &Namespace, name: String): Option<address> {
    if (ns.username_to_account.contains(name)) {
        option::some(*ns.username_to_account.borrow(name))
    } else {
        option::none()
    }
}

public fun username_of(ns: &Namespace, account: address): Option<String> {
    if (ns.account_to_username.contains(account)) {
        option::some(*ns.account_to_username.borrow(account))
    } else {
        option::none()
    }
}

public fun create_rules_id(ns: &Namespace): ID { ns.create_rules }

public fun username_name(username: &Username): String { username.name }

public fun username_namespace(username: &Username): ID { username.namespace }

public fun ticket_key(ticket: &CreateUsernameTicket): address { ticket.key }

public fun ticket_account(ticket: &CreateUsernameTicket): address { ticket.account }

public fun ticket_name(ticket: &CreateUsernameTicket): String { ticket.name }

// === Internal ===

fun assert_valid_name(name: &String) {
    assert!(name.length() > 0 && name.length() < 256, EInvalidName);
}

fun mint(ns: &mut Namespace, name: String, ctx: &mut TxContext): Username {
    assert!(!ns.taken.contains(name), ENameTaken);
    ns.taken.add(name, true);
    let username = Username { id: object::new(ctx), namespace: object::id(ns), name };
    event::emit(UsernameCreated {
        namespace: object::id(ns),
        name: username.name,
        by: ctx.sender(),
    });
    username
}

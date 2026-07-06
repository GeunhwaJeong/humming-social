// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Group primitive (Lens V3 `Group`).
///
/// Joining is rule-gated (`RuleSet<JoinGroupOp>`); admins can add or
/// remove members directly and ban accounts (covering Lens V3's
/// `BanMemberGroupRule` as a built-in).
module humming::group;

use humming::rules::{Self, Request, RuleSet, RuleSetCap};
use std::string::String;
use haneul::clock::Clock;
use haneul::event;
use haneul::table::{Self, Table};

const EAlreadyMember: u64 = 0;
const ENotMember: u64 = 1;
const EBanned: u64 = 2;
const EWrongGroup: u64 = 3;
const EWrongRuleSet: u64 = 4;
const EKeyMismatch: u64 = 5;
const EWrongCap: u64 = 6;
const ENotBanned: u64 = 7;

/// Operation marker: joining the group.
public struct JoinGroupOp {}

public struct Membership has drop, store {
    member_id: u64,
    joined_ms: u64,
}

public struct Group has key {
    id: UID,
    metadata_uri: String,
    /// ID of the shared `RuleSet<JoinGroupOp>`.
    join_rules: ID,
    members: Table<address, Membership>,
    member_count: u64,
    last_member_id: u64,
    banned: Table<address, bool>,
}

public struct GroupAdminCap has key, store {
    id: UID,
    group: ID,
}

/// Hot potato paired with a `Request<JoinGroupOp>`.
public struct JoinTicket {
    group: ID,
    key: address,
    account: address,
}

public struct GroupCreated has copy, drop {
    group: ID,
}

public struct MemberJoined has copy, drop {
    group: ID,
    account: address,
    member_id: u64,
}

public struct MemberLeft has copy, drop {
    group: ID,
    account: address,
}

public struct MemberBanned has copy, drop {
    group: ID,
    account: address,
}

public struct MemberUnbanned has copy, drop {
    group: ID,
    account: address,
}

public fun create(metadata_uri: String, ctx: &mut TxContext): (GroupAdminCap, RuleSetCap) {
    let (set, set_cap) = rules::new<JoinGroupOp>(ctx);
    let group = Group {
        id: object::new(ctx),
        metadata_uri,
        join_rules: object::id(&set),
        members: table::new(ctx),
        member_count: 0,
        last_member_id: 0,
        banned: table::new(ctx),
    };
    let admin_cap = GroupAdminCap { id: object::new(ctx), group: object::id(&group) };
    event::emit(GroupCreated { group: object::id(&group) });
    transfer::public_share_object(set);
    transfer::share_object(group);
    (admin_cap, set_cap)
}

// === Join (rule-gated) ===

public fun request_join(group: &Group, ctx: &mut TxContext): (JoinTicket, Request<JoinGroupOp>) {
    let account = ctx.sender();
    assert!(!group.members.contains(account), EAlreadyMember);
    assert!(!group.banned.contains(account), EBanned);
    let key = ctx.fresh_object_address();
    let ticket = JoinTicket { group: object::id(group), key, account };
    (ticket, rules::new_request(key, account))
}

public fun execute_join(
    group: &mut Group,
    join_rules: &RuleSet<JoinGroupOp>,
    ticket: JoinTicket,
    req: Request<JoinGroupOp>,
    clock: &Clock,
) {
    let JoinTicket { group: group_id, key, account } = ticket;
    assert!(group_id == object::id(group), EWrongGroup);
    assert!(object::id(join_rules) == group.join_rules, EWrongRuleSet);
    assert!(key == rules::request_key(&req), EKeyMismatch);
    rules::confirm(join_rules, req);
    insert_member(group, account, clock);
}

public fun leave(group: &mut Group, ctx: &TxContext) {
    let account = ctx.sender();
    assert!(group.members.contains(account), ENotMember);
    group.members.remove(account);
    group.member_count = group.member_count - 1;
    event::emit(MemberLeft { group: object::id(group), account });
}

// === Admin ===

/// Add a member directly, bypassing join rules.
public fun admin_add_member(
    group: &mut Group,
    cap: &GroupAdminCap,
    account: address,
    clock: &Clock,
) {
    assert_cap(group, cap);
    assert!(!group.members.contains(account), EAlreadyMember);
    assert!(!group.banned.contains(account), EBanned);
    insert_member(group, account, clock);
}

public fun admin_remove_member(group: &mut Group, cap: &GroupAdminCap, account: address) {
    assert_cap(group, cap);
    assert!(group.members.contains(account), ENotMember);
    group.members.remove(account);
    group.member_count = group.member_count - 1;
    event::emit(MemberLeft { group: object::id(group), account });
}

/// Ban an account: removes it if currently a member and blocks joining.
public fun ban(group: &mut Group, cap: &GroupAdminCap, account: address) {
    assert_cap(group, cap);
    if (group.members.contains(account)) {
        group.members.remove(account);
        group.member_count = group.member_count - 1;
        event::emit(MemberLeft { group: object::id(group), account });
    };
    group.banned.add(account, true);
    event::emit(MemberBanned { group: object::id(group), account });
}

public fun unban(group: &mut Group, cap: &GroupAdminCap, account: address) {
    assert_cap(group, cap);
    assert!(group.banned.contains(account), ENotBanned);
    group.banned.remove(account);
    event::emit(MemberUnbanned { group: object::id(group), account });
}

public fun set_metadata_uri(group: &mut Group, cap: &GroupAdminCap, metadata_uri: String) {
    assert_cap(group, cap);
    group.metadata_uri = metadata_uri;
}

// === Getters ===

public fun is_member(group: &Group, account: address): bool {
    group.members.contains(account)
}

public fun is_banned(group: &Group, account: address): bool {
    group.banned.contains(account)
}

public fun member_count(group: &Group): u64 { group.member_count }

public fun join_rules_id(group: &Group): ID { group.join_rules }

/// Returns (member_id, joined_ms).
public fun membership(group: &Group, account: address): (u64, u64) {
    assert!(group.members.contains(account), ENotMember);
    let m = group.members.borrow(account);
    (m.member_id, m.joined_ms)
}

public fun ticket_key(ticket: &JoinTicket): address { ticket.key }

public fun ticket_account(ticket: &JoinTicket): address { ticket.account }

// === Internal ===

fun assert_cap(group: &Group, cap: &GroupAdminCap) {
    assert!(cap.group == object::id(group), EWrongCap);
}

fun insert_member(group: &mut Group, account: address, clock: &Clock) {
    group.last_member_id = group.last_member_id + 1;
    group.member_count = group.member_count + 1;
    group.members.add(account, Membership {
        member_id: group.last_member_id,
        joined_ms: clock.timestamp_ms(),
    });
    event::emit(MemberJoined {
        group: object::id(group),
        account,
        member_id: group.last_member_id,
    });
}

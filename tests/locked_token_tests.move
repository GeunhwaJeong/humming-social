// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Tests for `humming::locked_token_rule`: the flash-proof token gate.
#[test_only]
module humming::locked_token_tests;

use humming::group::{Self, Group, JoinGroupOp};
use humming::locked_token_rule::{Self, Lock};
use humming::rules::{Self, RuleSet, RuleSetCap};
use humming::test_helpers::{new_clock, setup_group, setup_locked_group};
use sui::coin;
use sui::event;
use sui::sui::SUI;
use sui::test_scenario::{Self as ts};

const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;

const DAY_MS: u64 = 86_400_000;

#[test]
fun group_locked_token_join_and_withdraw_after_unlock() {
    let mut s = ts::begin(ADMIN);
    setup_locked_group(&mut s);
    let mut clock = new_clock(&mut s);

    // Alice locks 600, proves, and joins. The proof extends the lock.
    s.next_tx(ALICE);
    {
        let mut g = s.take_shared<Group>();
        let set = s.take_shared<RuleSet<JoinGroupOp>>();
        let mut lock = locked_token_rule::new_lock<SUI>(s.ctx());
        locked_token_rule::deposit(&mut lock, coin::mint_for_testing<SUI>(600, s.ctx()));
        let (ticket, mut req) = group::request_join(&g, s.ctx());
        locked_token_rule::prove(&set, &mut req, &mut lock, &clock);
        group::execute_join(&mut g, &set, ticket, req, &clock);
        assert!(group::is_member(&g, ALICE));
        assert!(locked_token_rule::locked_balance(&lock) == 600);
        assert!(locked_token_rule::unlock_ms(&lock) == DAY_MS);
        // Lock lifecycle events were emitted...
        assert!(event::events_by_type<locked_token_rule::LockCreated>().length() == 1);
        assert!(event::events_by_type<locked_token_rule::Deposited>().length() == 1);
        assert!(event::events_by_type<locked_token_rule::LockExtended>().length() == 1);
        // ...and a second proof at the same instant is silent: the
        // release time does not move, so no event is emitted.
        let mut req2 = rules::new_request<JoinGroupOp>(@0x0, ALICE);
        locked_token_rule::prove(&set, &mut req2, &mut lock, &clock);
        rules::destroy(req2);
        assert!(event::events_by_type<locked_token_rule::LockExtended>().length() == 1);
        locked_token_rule::keep(lock, s.ctx());
        ts::return_shared(g);
        ts::return_shared(set);
    };

    // After the lock period elapses, Alice withdraws everything.
    s.next_tx(ALICE);
    {
        clock.set_for_testing(DAY_MS);
        let mut lock = s.take_from_sender<Lock<SUI>>();
        let funds = locked_token_rule::withdraw(&mut lock, 600, &clock, s.ctx());
        assert!(funds.value() == 600);
        funds.burn_for_testing();
        locked_token_rule::destroy_empty(lock);
        assert!(event::events_by_type<locked_token_rule::Withdrawn>().length() == 1);
        assert!(event::events_by_type<locked_token_rule::LockDestroyed>().length() == 1);
    };

    clock.destroy_for_testing();
    s.end();
}

#[test]
#[expected_failure(abort_code = 1, location = humming::locked_token_rule)]
fun locked_token_withdraw_before_unlock_fails() {
    let mut s = ts::begin(ADMIN);
    setup_locked_group(&mut s);
    let clock = new_clock(&mut s);

    // Proving and withdrawing in the same breath must abort: this is
    // exactly the borrow-prove-return flash pattern the lock prevents.
    s.next_tx(ALICE);
    let mut g = s.take_shared<Group>();
    let set = s.take_shared<RuleSet<JoinGroupOp>>();
    let mut lock = locked_token_rule::new_lock<SUI>(s.ctx());
    locked_token_rule::deposit(&mut lock, coin::mint_for_testing<SUI>(600, s.ctx()));
    let (ticket, mut req) = group::request_join(&g, s.ctx());
    locked_token_rule::prove(&set, &mut req, &mut lock, &clock);
    let funds = locked_token_rule::withdraw(&mut lock, 600, &clock, s.ctx());
    funds.burn_for_testing();
    group::execute_join(&mut g, &set, ticket, req, &clock);
    locked_token_rule::keep(lock, s.ctx());
    ts::return_shared(g);
    ts::return_shared(set);
    clock.destroy_for_testing();
    s.end();
}

/// A rule demanding a lock period beyond MAX_LOCK_MS must be rejected
/// at configuration time: had it existed, a single `prove` against it
/// would freeze the lock's whole balance effectively forever.
#[test]
#[expected_failure(abort_code = 2, location = humming::locked_token_rule)]
fun locked_token_add_excessive_min_lock_ms_fails() {
    let mut s = ts::begin(ADMIN);
    setup_group(&mut s);

    s.next_tx(ADMIN);
    let mut set = s.take_shared<RuleSet<JoinGroupOp>>();
    let cap = s.take_from_sender<RuleSetCap>();
    locked_token_rule::add<JoinGroupOp, SUI>(
        &mut set,
        &cap,
        500,
        locked_token_rule::max_lock_ms() + 1,
        true,
    );
    s.return_to_sender(cap);
    ts::return_shared(set);
    s.end();
}

/// The boundary config is allowed, and a proof against it commits the
/// lock for exactly MAX_LOCK_MS — no further.
#[test]
fun locked_token_prove_at_max_lock_ms_bounds_unlock() {
    let mut s = ts::begin(ADMIN);
    setup_group(&mut s);

    s.next_tx(ADMIN);
    {
        let mut set = s.take_shared<RuleSet<JoinGroupOp>>();
        let cap = s.take_from_sender<RuleSetCap>();
        locked_token_rule::add<JoinGroupOp, SUI>(
            &mut set,
            &cap,
            500,
            locked_token_rule::max_lock_ms(),
            true,
        );
        s.return_to_sender(cap);
        ts::return_shared(set);
    };

    let clock = new_clock(&mut s);
    s.next_tx(ALICE);
    {
        let set = s.take_shared<RuleSet<JoinGroupOp>>();
        let mut lock = locked_token_rule::new_lock<SUI>(s.ctx());
        locked_token_rule::deposit(&mut lock, coin::mint_for_testing<SUI>(600, s.ctx()));
        let mut req = rules::new_request<JoinGroupOp>(@0x0, ALICE);
        locked_token_rule::prove(&set, &mut req, &mut lock, &clock);
        rules::destroy(req);
        assert!(locked_token_rule::unlock_ms(&lock) == locked_token_rule::max_lock_ms());
        locked_token_rule::keep(lock, s.ctx());
        ts::return_shared(set);
    };

    clock.destroy_for_testing();
    s.end();
}

/// A stale lock refuses to release funds until migrated: this is the
/// retirement lever for a future upgrade of the withdraw/prove logic.
#[test]
#[expected_failure(abort_code = 3, location = humming::locked_token_rule)]
fun stale_lock_blocks_withdraw() {
    let mut s = ts::begin(ALICE);
    let clock = new_clock(&mut s);

    s.next_tx(ALICE);
    let mut lock = locked_token_rule::new_lock<SUI>(s.ctx());
    locked_token_rule::deposit(&mut lock, coin::mint_for_testing<SUI>(100, s.ctx()));
    locked_token_rule::set_version_for_testing(&mut lock, 0);
    let funds = locked_token_rule::withdraw(&mut lock, 100, &clock, s.ctx());
    funds.burn_for_testing();
    locked_token_rule::keep(lock, s.ctx());
    clock.destroy_for_testing();
    s.end();
}

/// Self-service migration: the owner brings a stale lock current and
/// the funds move again — no cap, no admin in the loop.
#[test]
fun lock_migrate_restores_stale_lock() {
    let mut s = ts::begin(ALICE);
    let clock = new_clock(&mut s);

    s.next_tx(ALICE);
    let mut lock = locked_token_rule::new_lock<SUI>(s.ctx());
    locked_token_rule::deposit(&mut lock, coin::mint_for_testing<SUI>(100, s.ctx()));
    locked_token_rule::set_version_for_testing(&mut lock, 0);
    locked_token_rule::migrate(&mut lock);
    assert!(locked_token_rule::version(&lock) == rules::current_version());
    let funds = locked_token_rule::withdraw(&mut lock, 100, &clock, s.ctx());
    assert!(funds.value() == 100);
    funds.burn_for_testing();
    locked_token_rule::destroy_empty(lock);
    clock.destroy_for_testing();
    s.end();
}

/// Migrating a current lock aborts — migrate is an upgrade tool, not a
/// no-op (mirrors the shared-object migrate contract).
#[test]
#[expected_failure(abort_code = 4, location = humming::locked_token_rule)]
fun lock_migrate_current_version_aborts() {
    let mut s = ts::begin(ALICE);

    s.next_tx(ALICE);
    let mut lock = locked_token_rule::new_lock<SUI>(s.ctx());
    locked_token_rule::migrate(&mut lock);
    locked_token_rule::keep(lock, s.ctx());
    s.end();
}

#[test]
#[expected_failure(abort_code = 0, location = humming::locked_token_rule)]
fun locked_token_insufficient_locked_balance_fails() {
    let mut s = ts::begin(ADMIN);
    setup_locked_group(&mut s);
    let clock = new_clock(&mut s);

    s.next_tx(ALICE);
    let mut g = s.take_shared<Group>();
    let set = s.take_shared<RuleSet<JoinGroupOp>>();
    let mut lock = locked_token_rule::new_lock<SUI>(s.ctx());
    locked_token_rule::deposit(&mut lock, coin::mint_for_testing<SUI>(499, s.ctx()));
    let (ticket, mut req) = group::request_join(&g, s.ctx());
    locked_token_rule::prove(&set, &mut req, &mut lock, &clock);
    group::execute_join(&mut g, &set, ticket, req, &clock);
    locked_token_rule::keep(lock, s.ctx());
    ts::return_shared(g);
    ts::return_shared(set);
    clock.destroy_for_testing();
    s.end();
}
